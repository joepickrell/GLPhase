
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include "hmmLike.hcu"
#include "hmmLike.h"

using namespace std;

namespace HMMLikeCUDATest {

__global__ void GlobalFillEmit(const float *GLs, float *emit) {
  float nEmit[4];
  float nGLs[3];
  for (int i = 0; i < 3; ++i)
    nGLs[i] = GLs[i];
  HMMLikeCUDA::FillEmit(nGLs, nEmit);
  for (int i = 0; i < 4; ++i)
    emit[i] = nEmit[i];
}

void FillEmit(const vector<float> &GLs, vector<float> &emit) {

  assert(GLs.size() == 3);
  assert(emit.size() == 4);
  cudaError_t err = cudaSuccess;
  float *d_GLs;
  err = cudaMalloc(&d_GLs, 3 * sizeof(float));
  assert(err == cudaSuccess);

  err =
      cudaMemcpy(d_GLs, GLs.data(), 3 * sizeof(float), cudaMemcpyHostToDevice);
  assert(err == cudaSuccess);

  float *d_emit;
  err = cudaMalloc(&d_emit, 4 * sizeof(float));
  assert(err == cudaSuccess);

  GlobalFillEmit << <1, 1>>> (d_GLs, d_emit);

  err = cudaMemcpy(emit.data(), d_emit, 4 * sizeof(float),
                   cudaMemcpyDeviceToHost);
  assert(err == cudaSuccess);
};

__global__ void GlobalHmmLike(unsigned idx, const unsigned (*hapIdxs)[4],
                              const uint32_t *__restrict__ d_packedGLs,
                              unsigned packedGLStride,
                              const uint64_t *__restrict__ d_hapPanel,
                              const float *__restrict__ d_codeBook,
                              float *retLike, unsigned numSites) {
  *retLike = HMMLikeCUDA::hmmLike(idx, *hapIdxs, d_packedGLs, packedGLStride,
                                  d_hapPanel, d_codeBook, numSites);

  return;
}

float CallHMMLike(unsigned idx, const unsigned (*hapIdxs)[4],
                  unsigned packedGLStride, const vector<uint64_t> &h_hapPanel,
                  unsigned numSites) {

  cudaError_t err = cudaSuccess;

  /*
  copy initial hap indices to device memory
*/
  cout << "Copying hap indices to device\n";
  // allocate memory on device
  unsigned(*d_hapIdxs)[4];
  err = cudaMalloc(&d_hapIdxs, 4 * sizeof(unsigned));
  if (err != cudaSuccess) {
    cerr << "Failed to allocate\n";
    exit(EXIT_FAILURE);
  }

  // copy data across
  err = cudaMemcpy(d_hapIdxs, hapIdxs, 4 * sizeof(unsigned),
                   cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    cerr << "Failed to copy\n";
    exit(EXIT_FAILURE);
  }

  /*
  convert gd_packedGLs to raw ptr
*/
  assert(HMMLikeCUDA::gd_packedGLs);
  const uint32_t *d_packedGLPtr =
      thrust::raw_pointer_cast(HMMLikeCUDA::gd_packedGLs->data());

  assert(HMMLikeCUDA::gd_codeBook);
  const float *d_codeBookPtr =
      thrust::raw_pointer_cast(HMMLikeCUDA::gd_codeBook->data());

  /*
    copy haplotypes to device memory
  */
  cout << "Copying HapPanel to device\n";
  size_t hapPanelSize = h_hapPanel.size() * sizeof(uint64_t);

  // allocate memory on device
  uint64_t *d_hapPanel;
  err = cudaMalloc(&d_hapPanel, hapPanelSize);
  if (err != cudaSuccess) {
    cerr << "Failed to allocate hapPanel on device\n";
    exit(EXIT_FAILURE);
  }

  // copy data across
  err = cudaMemcpy(d_hapPanel, h_hapPanel.data(), hapPanelSize,
                   cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    cerr << "Failed to copy hapPanel to device\n";
    exit(EXIT_FAILURE);
  }

  // create result on device
  thrust::device_vector<float> d_like(1, 1);
  float *d_likePtr = thrust::raw_pointer_cast(&d_like[0]);
  /*
    run kernel
  */
  GlobalHmmLike << <1, 1>>> (idx, d_hapIdxs, d_packedGLPtr, packedGLStride,
                             d_hapPanel, d_codeBookPtr, d_likePtr, numSites);
  cudaDeviceSynchronize();
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Failed to run HMMLike kernel: " << cudaGetErrorString(err) << "\n";
    exit(EXIT_FAILURE);
  }

  thrust::host_vector<float> h_like = d_like;
  return d_like[0];
};

__global__ void GlobalUnpackGLsWithCodeBook(uint32_t GLcodes, float *GLs,
                                            const float *__restrict__ codeBook,
                                            unsigned char glIdx) {
  float nGLs[3];
  HMMLikeCUDA::UnpackGLsWithCodeBook(GLcodes, nGLs, codeBook, glIdx);
  for (int i = 0; i < 3; ++i)
    GLs[i] = nGLs[i];
}

void UnpackGLsWithCodeBook(uint32_t GLcodes, vector<float> &GLs,
                           unsigned char glIdx) {
  assert(GLs.size() == 3);

  thrust::device_vector<float> d_GLs(3, 0);
  float *d_GLPtr = thrust::raw_pointer_cast(d_GLs.data());
  const float *d_codeBook =
      thrust::raw_pointer_cast(HMMLikeCUDA::gd_codeBook->data());

  GlobalUnpackGLsWithCodeBook << <1, 1>>> (GLcodes, d_GLPtr, d_codeBook, glIdx);

  thrust::host_vector<float> h_GLs;
  h_GLs = d_GLs;
  for (int i = 0; i < 3; ++i)
    GLs[i] = h_GLs[i];
}

cudaError_t CopyTranToHost(vector<float> &tran) {

  assert(tran.size() <= NUMSITES * 3);
  return cudaMemcpyFromSymbol(tran.data(), HMMLikeCUDA::transitionMat,
                              sizeof(float) * tran.size(), 0,
                              cudaMemcpyDeviceToHost);
}

cudaError_t CopyMutMatToHost(vector<float> &mutMat) {

  assert(mutMat.size() == 4 * 4);
  return cudaMemcpyFromSymbol(mutMat.data(), HMMLikeCUDA::mutationMat,
                              sizeof(float) * 4 * 4, 0, cudaMemcpyDeviceToHost);
}
}
