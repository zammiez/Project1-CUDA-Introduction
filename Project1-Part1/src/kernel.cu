#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include <cuda_runtime.h>
#include "utilityCore.hpp"
#include "kernel.h"

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
 * Check for CUDA errors; print and exit if there was a problem.
 */
void checkCUDAError(const char *msg, int line = -1) {
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
        if (line >= 0) {
            fprintf(stderr, "Line %d: ", line);
        }
        fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}


/*****************
 * Configuration *
 *****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 1024

/*! Mass of one "planet." */
#define planetMass 3e8f

/*! Mass of the "star" at the center. */
#define starMass 5e10f

/*! Size of the starting area in simulation space. */
const float scene_scale = 1e2;

const int ApprStep = 1;

/***********************************************
 * Kernel state (pointers are device pointers) *
 ***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

glm::vec3 *dev_pos;
glm::vec3 *dev_vel;
glm::vec3 *dev_acc;


/******************
 * initSimulation *
 ******************/

__host__ __device__ unsigned int hash(unsigned int a) {
    a = (a + 0x7ed55d16) + (a << 12);
    a = (a ^ 0xc761c23c) ^ (a >> 19);
    a = (a + 0x165667b1) + (a << 5);
    a = (a + 0xd3a2646c) ^ (a << 9);
    a = (a + 0xfd7046c5) + (a << 3);
    a = (a ^ 0xb55a4f09) ^ (a >> 16);
    return a;
}

/**
 * Function for generating a random vec3.
 */
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
    thrust::default_random_engine rng(hash((int)(index * time)));
    thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

    return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
 * CUDA kernel for generating planets with a specified mass randomly around the star.
 */
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale, float mass) {
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (index < N) {
        glm::vec3 rand = generateRandomVec3(time, index);
        arr[index].x = scale * rand.x;
        arr[index].y = scale * rand.y;
        arr[index].z = 0.1 * scale * sqrt(rand.x * rand.x + rand.y * rand.y) * rand.z;
    }
}

/**
 * CUDA kernel for generating velocities in a vortex around the origin.
 * This is just to make for an interesting-looking scene.
 */
__global__ void kernGenerateCircularVelArray(int time, int N, glm::vec3 * arr, glm::vec3 * pos) {
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (index < N) {
        glm::vec3 R = glm::vec3(pos[index].x, pos[index].y, pos[index].z);
        float r = glm::length(R) + EPSILON;
        float s = sqrt(G * starMass / r);
        glm::vec3 D = glm::normalize(glm::cross(R / r, glm::vec3(0, 0, 1)));
        arr[index].x = s * D.x;
        arr[index].y = s * D.y;
        arr[index].z = s * D.z;
    }
}

/**
 * Initialize memory, update some globals
 */
void Nbody::initSimulation(int N) {
    numObjects = N;
    dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

    cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
    checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

    cudaMalloc((void**)&dev_vel, N * sizeof(glm::vec3));
    checkCUDAErrorWithLine("cudaMalloc dev_vel failed!");

    cudaMalloc((void**)&dev_acc, N * sizeof(glm::vec3));
    checkCUDAErrorWithLine("cudaMalloc dev_acc failed!");

    kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects, dev_pos, scene_scale, planetMass);
    checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

    kernGenerateCircularVelArray<<<fullBlocksPerGrid, blockSize>>>(2, numObjects, dev_vel, dev_pos);
    checkCUDAErrorWithLine("kernGenerateCircularVelArray failed!");

    cudaThreadSynchronize();
}


/******************
 * copyPlanetsToVBO *
 ******************/

/**
 * Copy the planet positions into the VBO so that they can be drawn by OpenGL.
 */
__global__ void kernCopyPlanetsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
    int index = threadIdx.x + (blockIdx.x * blockDim.x);

    float c_scale = -1.0f / s_scale;

    if (index < N) {
        vbo[4 * index + 0] = pos[index].x * c_scale;
        vbo[4 * index + 1] = pos[index].y * c_scale;
        vbo[4 * index + 2] = pos[index].z * c_scale;
        vbo[4 * index + 3] = 1;
    }
}

/**
 * Wrapper for call to the kernCopyPlanetsToVBO CUDA kernel.
 */
void Nbody::copyPlanetsToVBO(float *vbodptr) {
    dim3 fullBlocksPerGrid((int)ceil(float(numObjects) / float(blockSize)));

    kernCopyPlanetsToVBO<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, vbodptr, scene_scale);
    checkCUDAErrorWithLine("copyPlanetsToVBO failed!");

    cudaThreadSynchronize();
}


/******************
 * stepSimulation *
 ******************/

/**
 * Compute the acceleration on a body at `my_pos` due to the `N` bodies in the array `other_planets`.
 */

__device__ glm::vec3 accBySingleOtherPlanet(glm::vec3 this_planet,glm::vec3 other_planet,float mass)
{
	float dist = glm::length(other_planet - this_planet);
	dist *= dist;
	float gMag = G*mass / (dist + ZERO_ABSORPTION_EPSILON);//!!! divide by zero
	glm::vec3 g = glm::normalize(other_planet - this_planet)*gMag;
	return g;
}
__device__  glm::vec3 accelerate(int N, int iSelf, glm::vec3 this_planet, const glm::vec3 *other_planets) {
    // TODO: Compute the acceleration on `my_pos` due to:
    //   * The star at the origin (with mass `starMass`)
    //   * All of the *other* planets (with mass `planetMass`)
    // Return the sum of all of these contributions.

    // HINT: You may want to write a helper function that will compute the acceleration at
    //   a single point due to a single other mass. Be careful that you protect against
    //   division by very small numbers.
    // HINT: Use Newtonian gravitational acceleration:
    //       G M
    //  g = -----
    //       r^2
    //  where:
    //    * G is the universal gravitational constant (already defined for you)
    //    * M is the mass of the other object
    //    * r is the distance between this object and the other object
	glm::vec3 g(0.0f);

	//g by Origin Star
	g += accBySingleOtherPlanet(this_planet,glm::vec3(0.0f),starMass);
	//g by others
	
	for (int i = 0; i < N; i += ApprStep)
	{
		if (i != iSelf) 
		{
			g += accBySingleOtherPlanet(this_planet, other_planets[i],planetMass);
		}
	}
    //return glm::vec3(0.0f);
	return g;
}

/**
 * For each of the `N` bodies, update its acceleration.
 * Compute the total instantaneous acceleration using `accelerate`, then store that into `acc`.
 */
__global__ void kernUpdateAcc(int N, float dt, const glm::vec3 *pos, glm::vec3 *acc) {
    // TODO: implement updateAccArray.
	int idx = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (idx < N)
	{
		acc[idx] = accelerate(N, idx, pos[idx], pos);
	}
    // This function body runs once on each CUDA thread.
    // To avoid race conditions, each instance should only write ONE value to `acc`!
}

/**
 * For each of the `N` bodies, update its velocity, then update its position, using a
 * simple Euler integration scheme. Acceleration must be updated before calling this kernel.
 */
__global__ void kernUpdateVelPos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel, const glm::vec3 *acc) {
    // TODO: implement updateVelocityPosition
	int idx = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (idx < N){
		vel[idx] += acc[idx] * dt;
		pos[idx] += vel[idx] * dt;
	}
}

/**
 * Step the entire N-body simulation by `dt` seconds.
 */
void Nbody::stepSimulation(float dt) {
    // TODO: Using the CUDA kernels you wrote above, write a function that
    // calls the kernels to perform a full simulation step.
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

	cudaEvent_t start, stop;
	float elapsedTime;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	cudaEventRecord(start,0);
	
	kernUpdateAcc <<< fullBlocksPerGrid, threadsPerBlock >>>(numObjects, dt, dev_pos, dev_acc);
	
	cudaEventRecord(stop,0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime, start, stop);
	printf( "\n1 -- kernUpdateAcc Time = %.2fms",elapsedTime );


	cudaEventRecord(start, 0);
	kernUpdateVelPos <<< fullBlocksPerGrid, threadsPerBlock >> > (numObjects, dt, dev_pos, dev_vel, dev_acc);
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime, start, stop);
	printf("\n2 -- kernUpdateVelPos Time = %.4fms", elapsedTime);
}

void Nbody::endSimulation()
{
    cudaFree(dev_acc);
    cudaFree(dev_vel);
    cudaFree(dev_pos);
}
