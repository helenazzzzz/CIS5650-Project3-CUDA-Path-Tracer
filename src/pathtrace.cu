#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/partition.h>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

struct alive
{
	__host__ __device__
		bool operator()(const PathSegment& x)
	{
		return !x.dead;
	}
};

struct sort_by_material
{
	__host__ __device__
		bool operator()(const ShadeableIntersection& x1, const ShadeableIntersection& x2)
	{
		return x1.materialId < x2.materialId;
	}
};

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static ShadeableIntersection* dev_first_pass = NULL;
static Triangle* dev_tris = NULL;
static cudaArray_t* imgArrays = NULL;
static cudaTextureObject_t* textureObjects = NULL;
static Geom* dev_lights = NULL;
size_t num_textures = 0;
static cudaTextureObject_t* dev_tex = NULL;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;
	currentlyCaching = false;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// TODO: initialize any extra device memeory you need

	cudaMalloc(&dev_first_pass, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_tris, scene->tris.size() * sizeof(Triangle));
	cudaMemcpy(dev_tris, scene->tris.data(), scene->tris.size() * sizeof(Triangle), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_lights, scene->lights.size() * sizeof(Geom));
	cudaMemcpy(dev_lights, scene->lights.data(), scene->lights.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	num_textures = hst_scene->textures.size();
	imgArrays = new cudaArray_t[num_textures];
	textureObjects = new cudaTextureObject_t[num_textures];

	for (size_t i = 0; i < hst_scene->textures.size(); i++) {
		Image mp = hst_scene->textures[i];

		auto channelDesc = cudaCreateChannelDesc<float4>();
		cudaMallocArray(&imgArrays[i], &channelDesc, mp.width, mp.height);
		cudaMemcpy2DToArray(imgArrays[i], 0, 0, mp.imgdata.data(), mp.width * sizeof(float4), mp.width * sizeof(float4), mp.height, cudaMemcpyHostToDevice);

		cudaResourceDesc resDesc;
		memset(&resDesc, 0, sizeof(resDesc));
		resDesc.resType = cudaResourceTypeArray;
		resDesc.res.array.array = imgArrays[i];

		cudaTextureDesc texDesc;
		memset(&texDesc, 0, sizeof(texDesc));
		texDesc.addressMode[0] = cudaAddressModeWrap;  // Set your desired addressing mode
		texDesc.addressMode[1] = cudaAddressModeWrap;
		texDesc.filterMode = cudaFilterModeLinear;  // Set your desired filtering mode
		texDesc.readMode = cudaReadModeElementType;
		texDesc.normalizedCoords = 1;

		cudaCreateTextureObject(&textureObjects[i], &resDesc, &texDesc, NULL);
	}

	cudaMalloc(&dev_tex, num_textures * sizeof(cudaTextureObject_t));
	cudaMemcpy(dev_tex, textureObjects, num_textures * sizeof(cudaTextureObject_t), cudaMemcpyHostToDevice);
	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
			// TODO: clean up any extra device memory you created
	cudaFree(dev_tris);
	for (size_t i = 0; i < num_textures; i++) {
		cudaDestroyTextureObject(textureObjects[i]);
		cudaFreeArray(imgArrays[i]);
	}
	
	cudaFree(dev_lights);
	checkCUDAError("pathtraceFree");
}

void pathtraceFreeAll() {
	cudaFree(dev_first_pass);
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments, float lens_radius, float focal_distance)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];
				
		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f);

		segment.dead = false;
		segment.spec = false;

		// TODO: implement antialiasing by jittering the ray
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);

		// random

		if (lens_radius > 0.0f) {
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			float x = (u01(rng) - 0.5) * 2;
			float y = (u01(rng) - 0.5) * 2;
			glm::vec2 offset;

			if (pow(x, 2) > pow(y, 2)) {

				float angle = (PI / 4) * (y / x);
				offset = glm::vec2(x * cos(angle), x * sin(angle));

			}
			else {

				float angle = (PI / 2) - (PI / 4 * (x / y));
				offset = glm::vec2(y * cos(angle), y * sin(angle));
			}

			offset *= lens_radius;
			float ft = -focal_distance / segment.ray.direction.z;

			glm::vec3 pFocus = segment.ray.origin + ft * segment.ray.direction;

			segment.ray.origin.x += offset.x;
			segment.ray.origin.y += offset.y;

			segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);

			
		}
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	const int depth,
	const int num_paths,
	PathSegment* pathSegments,
	Geom* geoms,
	const int geoms_size,
	Triangle* tris,
	ShadeableIntersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;
		glm::vec2 uv;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;
		glm::vec2 tmp_uv;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];
			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else {
				t = meshIntersectionTest(geom, tris, tmp_uv, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
				uv = tmp_uv;
			}
		}

		
		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else if (hit_geom_index < geoms_size)
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].hitGeomIdx = hit_geom_index;
			intersections[path_index].uv = uv;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	const int iter, 
	const int num_paths, 
	const ShadeableIntersection* shadeableIntersections, 
	PathSegment* pathSegments, 
	const Material* materials,
	const int depth,
	const cudaTextureObject_t* tex, 
	const int envMap, 
	const Geom* lights, 
	const int numLights, 
	Geom* geoms, 
	const int geoms_size, 
	Triangle* tris
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment& path = pathSegments[idx];
		if (!path.dead) {
			if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
				thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, depth + 1);
				thrust::uniform_real_distribution<float> u01(0, 1);

				Material material = materials[intersection.materialId];
				glm::vec3 materialColor = material.color;

				// If the material indicates that the object was a light, "light" the ray
				glm::vec3 intersection_point = getPointOnRay(path.ray, intersection.t);

				// apply direct lighting
				if (material.emittance == 0 && !material.hasReflective) {
					path.spec = false;
					int rand;
					if (envMap == -1) {
						rand = int(u01(rng) * numLights) % numLights;
					}
					else {
						rand = int(u01(rng) * (numLights + 1)) % (numLights + 1);
					}

					glm::vec3 L;
					float pdf;
					Ray light;
					int target = -1;

					glm::vec2 xi = glm::vec2(-0.5f) + glm::vec2(u01(rng), u01(rng));
					if (rand == numLights) {
						light.direction = calculateRandomDirectionInHemisphere(intersection.surfaceNormal, rng);
						light.origin = intersection_point + 0.001f * light.direction;
						glm::vec3 d = light.direction;
						glm::vec2 uv = glm::vec2(atan2(d.z, d.x), asin(d.y));
						uv *= glm::vec2(0.1591, -0.3183);
						uv += 0.5;
						pdf = abs(dot((light.direction), -intersection.surfaceNormal));

						float4 env_color = tex2D<float4>(tex[envMap], uv.x, uv.y);
						L.x = env_color.x;
						L.y = env_color.y;
						L.z = env_color.z;
					}
					else {
						Geom l = lights[rand];
						target = l.index;
						glm::vec3 point_on_light;
						
						pdf = closestPointOnCube(l, xi, intersection_point, point_on_light, light, u01(rng));
						light.direction = point_on_light - intersection_point;
						L = materials[l.materialid].color * materialColor * pow(abs(dot(intersection.surfaceNormal, -light.direction)), 2.0f) / pdf;
					}
					float t;
					float t_min = FLT_MAX;
					int hit_geom_index = -1;
					bool outside = true;


					for (int i = 0; i < geoms_size; i++)
					{
						Geom& geom = geoms[i];
						if (geom.type == CUBE)
						{
							t = boxIntersectionTest(geom, light, glm::vec3(), glm::vec3(), outside);
						}
						else if (geom.type == SPHERE)
						{
							t = sphereIntersectionTest(geom, light, glm::vec3(), glm::vec3(), outside);
						}
						else {
							t = meshIntersectionTest(geom, tris, glm::vec2(), light, glm::vec3(), glm::vec3(), outside);
						}
						if (t > 0.0f && t_min > t)
						{
							t_min = t;
							hit_geom_index = i;
						}
					}

					if (pdf < 0.001f) {
						L = glm::vec3(0.0f);
					}
					else {
						path.color += path.color * L;
						float maxComponent = max(max(path.color.r, path.color.g), path.color.b);
						if (maxComponent > 1.0f) {
							path.color /= maxComponent;
						}
					}
					
				}
				else {
					path.spec = true;
				}

				scatterRay(path, intersection_point, intersection.surfaceNormal, material, rng, depth);
				if (geoms[intersection.hitGeomIdx].textureIdx != -1) {
					float4 c = tex2D<float4>(tex[geoms[intersection.hitGeomIdx].textureIdx], intersection.uv.x, intersection.uv.y);
					path.color *= glm::vec3(c.x, c.y, c.z);
				}
				else if (!material.hasReflective && !material.hasRefractive) {
					path.color *= material.color;
				}

				// Russian Roulette
				if (depth > 2) {
					float maxComponent = max(max(path.color.r, path.color.g), path.color.b);
					if (maxComponent > u01(rng)) {
						path.color /= maxComponent;
					}
					else {
						path.dead = true;
					}
				}
				// If there was no intersection, color the ray black.
				// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
				// used for opacity, in which case they can indicate "no opacity".
				// This can be useful for post-processing and image compositing.
			}
			else {
				// sample environment map 
				if (envMap != -1) {
					glm::vec3 d = path.ray.direction;
					glm::vec2 uv = glm::vec2(atan2(d.z, d.x), asin(d.y));
					uv *= glm::vec2(0.1591, -0.3183);
					uv += 0.5;

					float4 env_color = tex2D<float4>(tex[envMap], uv.x, uv.y);
					if (depth == 1) {
						path.color.x = env_color.x;
						path.color.y = env_color.y;
						path.color.z = env_color.z;
					}
					else if (path.spec) {
						path.color.x *= env_color.x;
						path.color.y *= env_color.y;
						path.color.z *= env_color.z;
					}
					
				}
				else {
					path.color = glm::vec3(0.0f);
				}
				path.dead = true;
			}
		}
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	const int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

__global__ void cacheFirstPass(int n, ShadeableIntersection* first, ShadeableIntersection* all) {

	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < n) {
		first[index] = all[index];
	}

}

__global__ void getFirstPass(int n, ShadeableIntersection* first, ShadeableIntersection* all) {
	
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < n) {
		all[index] = first[index];
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths, guiData->lens_radius, guiData->focal_distance);
	checkCUDAError("generate camera ray");

	if (currentlyCaching && !guiData->caching) {
		currentlyCaching = false;
	}

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int all_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {
		int num_paths = dev_path_end - dev_paths;

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d) / blockSize1d;

		// tracing
		if (depth == 0 && currentlyCaching) {
			getFirstPass << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_first_pass, dev_intersections);
		}
		else {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_tris
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();

		}
		if (depth == 0 && guiData->caching && !currentlyCaching) {
			cacheFirstPass << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_first_pass, dev_intersections);
			currentlyCaching = true;
		}

		depth++;

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	  // evaluating the BSDF.
	  // Start off with just a big kernel that handles all the different
	  // materials you have in the scenefile.
	  // TODO: compare between directly shading the path segments and shading
	  // path segments that have been reshuffled to be contiguous in memory.
		if (guiData->material_sort) {
			thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, sort_by_material());
		}

		shadeFakeMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			depth,
			dev_tex,
			hst_scene->envMap,
			dev_lights,
			hst_scene->numLights
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_tris
			);
		iterationComplete = (depth == hst_scene->state.traceDepth); // TODO: should be based off stream compaction results.

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}

		dev_path_end = thrust::partition(thrust::device, dev_paths, dev_paths + num_paths, alive());
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (all_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
