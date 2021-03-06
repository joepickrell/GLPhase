#include "hmmLike.hcu"

using namespace std;

namespace HMMLikeCUDA {

// basically avoid singularity or floating point error
__constant__ float norm;
__constant__ float transitionMat[NUMSITES * 3];
__constant__ float mutationMat[4 * 4];

__device__ void UnpackGLsWithCodeBook(uint32_t GLcodes, float(&GLs)[3],
                                      const float *__restrict__ codeBook,
                                      unsigned char glIdx) {

  // create mask that gives me just the rightmost n bits
  const uint32_t mask = (1 << BITSPERCODE) - 1;

  // push the code of interest to the right
  uint32_t GLcode =
      GLcodes >> UINT32T_SIZE - (BITSPERCODE * glIdx) - BITSPERCODE;

  // keep onlyt the code of interest
  GLcode &= mask;
  GLs[0] = codeBook[2 * GLcode];
  GLs[1] = codeBook[2 * GLcode + 1];
  GLs[2] = max(1 - GLs[0] - GLs[1], 0.0f);
}

/* deprecated
__device__ void UnpackGLs(unsigned char GLset, float (&GLs)[3]) {

GLs[0] = (((GLset >> 4) & 15) + 0.5f) / 16;
GLs[1] = ((GLset & 15) + 0.5f) / 16;
GLs[2] = max(1 - GLs[0] - GLs[1], 0.0f);
}
*/

__device__ void FillEmit(const float(&GLs)[3], float(&emit)[4]) {

  for (unsigned i = 0; i < 4; ++i)
    emit[i] = mutationMat[i] * GLs[0] + mutationMat[i + 4 * 1] * GLs[1] +
              mutationMat[i + 4 * 2] * GLs[1] + mutationMat[i + 4 * 3] * GLs[2];
}

// test if bit I is 1
__device__ uint64_t test(const uint64_t *P, unsigned I) {
  return (P[I >> WORDSHIFT] >> (I & WORDMOD)) & static_cast<uint64_t>(1);
}

// this should add up to around 88 registers
// 1 + 4 + 2 + 1 + 2 = 10 registers, maybe optimized away by compiler?
__device__ float hmmLike(unsigned idx, const unsigned(&hapIdxs)[4],
                         const uint32_t *__restrict__ d_packedGLs,
                         unsigned packedGLStride,
                         const uint64_t *__restrict__ d_hapPanel,
                         const float *__restrict__ d_codeBook,
                         unsigned numSites) {

  // pull the four haplotypes into f0, f1, m0 and m1
  const uint64_t *f0 = &d_hapPanel[hapIdxs[0] * WN], // 8 registers?
      *f1 = &d_hapPanel[hapIdxs[1] * WN], *m0 = &d_hapPanel[hapIdxs[2] * WN],
                 *m1 = &d_hapPanel[hapIdxs[3] * WN];

  // ##########
  // Convert packed GLs back to floats

  float GLs[3]; // 3 registers
  UnpackGLsWithCodeBook(d_packedGLs[idx], GLs, d_codeBook, 0);

  // pull out phase emission and transition probabilities
  float emit[4]; // 4 registers
  FillEmit(GLs, emit);

  float sum, score = 0; // 2 registers

  // l00 = prob of 0|0 phase, etc.
  // all set to 1/4 * emission probability
  // 4 registers
  float l00 = 0.25f * emit[(test(f0, 0) << 1) | test(m0, 0)],
        l01 = 0.25f * emit[(test(f0, 0) << 1) | test(m1, 0)];
  float l10 = 0.25f * emit[(test(f1, 0) << 1) | test(m0, 0)],
        l11 = 0.25f * emit[(test(f1, 0) << 1) | test(m1, 0)];

  //  1 register
  for (uint32_t site = 1; site < numSites; ++site) {
    // move to next site for e and t

    // #########
    // Convert packed GLs back to floats

    const unsigned char numGLsPerUint32 = UINT32T_SIZE / BITSPERCODE;

    // poor man's modulo: site % numGLsPerUint32 = (site & (numGLsPerUint32 -
    // 1))
    // Works only if numGLsPerUint32 is a factor of 2
    //
    // poor man's log2(n) =  __ffs(n) - 1
    // only works if n is a factor of 2
    const unsigned packedGLIdx =
        idx + (site >> (__ffs(numGLsPerUint32) - 1)) * packedGLStride;
    const unsigned char withinUINTCodeNum = site & (numGLsPerUint32 - 1);
    UnpackGLsWithCodeBook(d_packedGLs[packedGLIdx], GLs, d_codeBook,
                          withinUINTCodeNum);

    // fill emit with next site's emission matrix
    FillEmit(GLs, emit);

    // bxx = backward probabilities of being in phase xx
    // 4 registers
    const float b00 = l00 * transitionMat[site * 3] +
                      (l01 + l10) * transitionMat[site * 3 + 1] +
                      l11 * transitionMat[site * 3 + 2];
    const float b01 = l01 * transitionMat[site * 3] +
                      (l00 + l11) * transitionMat[site * 3 + 1] +
                      l10 * transitionMat[site * 3 + 2];
    const float b10 = l10 * transitionMat[site * 3] +
                      (l00 + l11) * transitionMat[site * 3 + 1] +
                      l01 * transitionMat[site * 3 + 2];
    const float b11 = l11 * transitionMat[site * 3] +
                      (l01 + l10) * transitionMat[site * 3 + 1] +
                      l00 * transitionMat[site * 3 + 2];

    l00 = b00 * emit[(test(f0, site) << 1) | test(m0, site)];
    l01 = b01 * emit[(test(f0, site) << 1) | test(m1, site)];
    l10 = b10 * emit[(test(f1, site) << 1) | test(m0, site)];
    l11 = b11 * emit[(test(f1, site) << 1) | test(m1, site)];

    // rescale probabilities if they become too small
    // hopefully this does not happen too often...
    if ((sum = l00 + l01 + l10 + l11) < norm) {
      sum = 1.0f / sum;
      score -= __logf(sum); // add sum to score
      l00 *= sum;
      l01 *= sum;
      l10 *= sum;
      l11 *= sum;
    }
  }

  return score + __logf(l00 + l01 + l10 + l11);
};

// definition of HMM kernel
__global__ void findHapSet(const uint32_t *__restrict__ d_packedGLs,
                           const uint64_t *__restrict__ d_hapPanel,
                           const unsigned *__restrict__ d_hapIdxs,
                           const unsigned *__restrict__ d_extraPropHaps,
                           unsigned *d_chosenHapIdxs, unsigned numSamples,
                           unsigned numCycles, curandStateXORWOW_t *globalState,
                           const float *__restrict__ d_codeBook,
                           unsigned numSites
#ifdef DEBUG
                           ,
                           float *d_likes
#endif
                           ) {

  const float S = 1;
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < numSamples) {

    curandStateXORWOW_t localState = globalState[idx];

    unsigned hapIdxs[4];
    for (int i = 0; i < 4; ++i)
      hapIdxs[i] = d_hapIdxs[idx + numSamples * i];

    // define emission matrix
    float curr = hmmLike(idx, hapIdxs, d_packedGLs, numSamples, d_hapPanel,
                         d_codeBook, numSites);

#ifdef DEBUG
    // debugging ...
    if (idx == 0)
      d_likes[0] = curr;
#endif

    // pick a random haplotype to replace with another one from all
    // haplotypes.  calculate the new probability of the model given
    // those haplotypes.
    // accept new set if probability has increased.
    // otherwise, accept with penalized probability

    for (int cycle = 0; cycle < numCycles; ++cycle) {

      // replace a sample
      unsigned replaceHapNum = curand(&localState) & 3;
      unsigned origHap = hapIdxs[replaceHapNum];

      hapIdxs[replaceHapNum] = d_extraPropHaps[idx + cycle * numSamples];
      float prop = hmmLike(idx, hapIdxs, d_packedGLs, numSamples, d_hapPanel,
                           d_codeBook, numSites);

      // accept new set
      if (curand_uniform(&localState) < __expf((prop - curr) * S))
        curr = prop;
      // reject new set
      else
        hapIdxs[replaceHapNum] = origHap;

#ifdef DEBUG
      if (idx == 0)
        d_likes[cycle + 1] = curr;
#endif

    } // last of numCycles
    for (int i = 0; i < 4; ++i)
      d_chosenHapIdxs[idx + numSamples * i] = hapIdxs[i];

    // update global state
    globalState[idx] = localState;

    // return nothing.  d_chosenHapIdxs is the return data
    return;
  }
}

// initializes random number generator states
__global__ void setup_generators(curandStateXORWOW_t *state, size_t stateSize,
                                 unsigned long seed) {

  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < stateSize)
    curand_init(seed, idx, 0, &state[idx]);
}

void InitializeConstants() {

  cudaError_t err;

  // also, this looks like as good of a place as any to define some constants
  float localNorm = powf(FLT_MIN, 2.0f / 3.0f);
  err = cudaMemcpyToSymbol(norm, &localNorm, sizeof(float), 0,
                           cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    cerr << "Error copying value to symbol: " << cudaGetErrorString(err)
         << "\n";

    exit(EXIT_FAILURE);
  }
}

void SetDevice(int devID) {

  assert(devID >= 0);

  cudaError_t err;
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Error before starting: " << cudaGetErrorString(err) << "\n";

    exit(EXIT_FAILURE);
  }

  cout << "Setting to device ID [" << devID << "]" << endl;
  err = cudaSetDevice(devID);
  if (err != cudaSuccess) {
    cout << "cudaSetDevice returned " << err << "\n";
    cout << "Result = FAIL\n";
    exit(EXIT_FAILURE); //
  }
  InitializeConstants();
}

void CheckDevice() {

  cudaError_t err;
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Error before starting: " << cudaGetErrorString(err) << "\n";

    exit(EXIT_FAILURE);
  }

  int deviceCount = 0;

  // note your project will need to link with cuda.lib files on windows
  cout << "Querrying CUDA Device(s)...\n\n";

  err = cudaGetDeviceCount(&deviceCount);

  if (err != cudaSuccess) {
    cout << "cuDeviceGetCount returned " << err << "\n";
    cout << "Result = FAIL\n";
    exit(EXIT_FAILURE); //
  }

  cout << "Found " << deviceCount << " device(s)" << endl;

  for (int i = 0; i < deviceCount; ++i) {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, i);
    cout << "Device number: " << i << endl;
    cout << "Name: " << prop.name << endl;
    cout << "Compute capability: " << prop.major << '.' << prop.minor << endl;

    if (prop.major < 3 || prop.major == 3 && prop.minor < 5) {
      cerr << "Compute capability >= 3.5 required" << endl;
      exit(EXIT_FAILURE);
    }

    // set device to use more L1 cache than shared mem
    cout << "\nSetting device to prefer L1 cache over shared mem\n";
    if (cudaDeviceSetCacheConfig(cudaFuncCachePreferL1) != cudaSuccess) {
      cerr << "Could not set device caching preference to L1\n";
    }

    cudaFuncCache pCacheConfig;
    if (cudaDeviceGetCacheConfig(&pCacheConfig) != cudaSuccess) {
      cerr << "Could not get device caching preference\n";
    }
    if (pCacheConfig == cudaFuncCachePreferL1)
      cout << "Device caching preference is set to prefer L1" << endl;
    else
      cout << "Device caching preference is not set to prefer L1" << endl;
  }

  return;
}

void CopyTranToDevice(const vector<float> &tran) {

  assert(tran.size() <= NUMSITES * 3);
  // fixme: first three values of tran are never used
  for (unsigned i = 3; i < tran.size(); i += 3)
    assert(abs(tran[i] + 2 * tran[i + 1] + tran[i + 2] - 1) < 0.1);
  cudaError_t err = cudaMemcpyToSymbol(transitionMat, tran.data(),
                                       sizeof(float) * tran.size(), 0,
                                       cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    stringstream outerr(
        "Could not copy transition matrix to device with error: ");
    outerr << err;
    throw std::runtime_error(outerr.str());
  }
}

void CopyMutationMatToDevice(const float (*mutMat)[4][4]) {

  vector<float> h_mutMat(4 * 4);
  for (int i = 0; i < 4; ++i)
    for (int j = 0; j < 4; ++j)
      h_mutMat[i + 4 * j] = ((*mutMat))[i][j];

  cudaError_t err =
      cudaMemcpyToSymbol(mutationMat, h_mutMat.data(), sizeof(float) * 4 * 4, 0,
                         cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    stringstream outerr(
        "Could not copy mutation matrix to device with error: ");
    outerr << err;
    throw std::runtime_error(outerr.str());
  }
}

thrust::device_vector<uint32_t> *gd_packedGLs;
void CopyPackedGLsToDevice(const vector<uint32_t> &packedGLs) {
  thrust::device_vector<uint32_t> fillPackedGLs(packedGLs);

  // gotta manually new the thrust vector because it'll get deleted too late
  // otherwise...
  if (!gd_packedGLs)
    gd_packedGLs = new thrust::device_vector<uint32_t>;
  gd_packedGLs->swap(fillPackedGLs);
}

thrust::device_vector<float> *gd_codeBook;
void CopyCodeBookToDevice(const vector<pair<float, float> > &codeBook) {

  thrust::host_vector<float> h_codeBook;
  h_codeBook.reserve(codeBook.size() * 2);
  for (unsigned idx = 0; idx < codeBook.size(); ++idx) {
    h_codeBook.push_back(codeBook[idx].first);
    h_codeBook.push_back(codeBook[idx].second);
  }

  // gotta manually new the thrust vector because it'll get deleted too late
  // otherwise...
  if (!gd_codeBook)
    gd_codeBook = new thrust::device_vector<float>;
  *gd_codeBook = h_codeBook;
}

void Cleanup() {
  if (gd_packedGLs) {
    delete gd_packedGLs;
    gd_packedGLs = NULL;
  }
  if (gd_codeBook) {
    delete gd_codeBook;
    gd_codeBook = NULL;
  }

  // being a good citizen and flushing device
  cudaDeviceReset();
}

void RunHMMOnDevice(const vector<uint64_t> &hapPanel,
                    const vector<unsigned> &extraPropHaps, unsigned numSites,
                    unsigned numSamples, unsigned numCycles,
                    vector<unsigned> &hapIdxs, unsigned long seed) {
  assert(numSites <= NUMSITES);
  assert(gd_packedGLs); // make sure pointer points to something

  // make sure packed GLs have the right size
  size_t expectedSize = numSamples * ceil(static_cast<float>(numSites) *
                                          BITSPERCODE / UINT32T_SIZE);
  if (gd_packedGLs->size() != expectedSize) {
    ostringstream err;
    err << "[RunHMMOnDevice] gd_packed GLs has wrong size: "
        << gd_packedGLs->size() << "\n\texpected size: " << expectedSize;
    throw std::runtime_error(err.str());
  }
  assert(gd_codeBook); // make sure pointer points to something
  assert(gd_codeBook->size() == 2 * (1 << BITSPERCODE));

  assert(hapPanel.size() >=
         ceil(static_cast<float>(numSites) / WORDSIZE) *
             (*max_element(extraPropHaps.begin(), extraPropHaps.end()) + 1));
  assert(hapIdxs.size() == numSamples * 4);
  assert(extraPropHaps.size() == numSamples * numCycles);

/*
  copy packedGLs to device memory
*/
/* hopefully we don't need this code anymore...
#ifdef DEBUG
cout << "[HMMLikeCUDA] Copying packed GLs to device\n";
#endif

size_t glSize = packedGLs.size() * sizeof(char);

// allocate memory on device
char *d_packedGLs;
err = cudaMalloc(&d_packedGLs, glSize);
if (err != cudaSuccess) {
  cerr << "Failed to allocate packed GLs on device\n";
  exit(EXIT_FAILURE);
}

// copy data across
err =
    cudaMemcpy(d_packedGLs, packedGLs.data(), glSize, cudaMemcpyHostToDevice);
if (err != cudaSuccess) {
  cerr << "Failed to copy packed GLs to device\n";
  exit(EXIT_FAILURE);
}
*/

#ifdef DEBUG
  // debug info
  cout << "Hap Idxs before sampling: ";
  for (int i = 0; i < hapIdxs.size(); ++i)
    cout << hapIdxs[i] << " ";
  cout << endl;
#endif

  cudaError_t err = cudaSuccess;
  /*
    Set up numSamp random generator states
   */
  curandStateXORWOW_t *devStates;
  cudaMalloc(&devStates, numSamples * sizeof(curandStateXORWOW_t));

  // set up generators
  unsigned threadsPerBlock = 128;
  unsigned blocksPerRun = (numSamples + threadsPerBlock - 1) / threadsPerBlock;

  setup_generators << <blocksPerRun, threadsPerBlock>>>
      (devStates, numSamples, seed);
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Failed to set up random states kernel: " << cudaGetErrorString(err)
         << "\n";
    exit(EXIT_FAILURE);
  }

/*
  copy haplotypes to device memory
*/
#ifdef DEBUG
  cout << "[HMMLikeCUDA] Copying HapPanel to device\n";
#endif
  thrust::device_vector<uint64_t> d_hapPanel(hapPanel.begin(), hapPanel.end());

/*
  copy initial hap indices to device memory
*/
#ifdef DEBUG
  cout << "[HMMLikeCUDA] Copying hap indices to device\n";
#endif
  thrust::device_vector<unsigned> d_hapIdxs(hapIdxs.begin(), hapIdxs.end());

/*
  copy extra proposal haps to device memory
*/
#ifdef DEBUG
  cout << "[HMMLikeCUDA] Copying extra proposal haps to device\n";
#endif
  thrust::device_vector<unsigned> d_extraPropHaps(extraPropHaps.begin(),
                                                  extraPropHaps.end());

  /*
    allocate device memory for results
  */
  thrust::device_vector<unsigned> d_chosenHapIdxs(hapIdxs.size());

#ifdef DEBUG
  /*
    allocate device memory for debugging floats
  */
  thrust::device_vector<float> d_likes(numCycles + 1);
  float *d_likePtr = thrust::raw_pointer_cast(d_likes.data());
#endif

  // determine thread and block size
  threadsPerBlock = 128;
  blocksPerRun = (numSamples + threadsPerBlock - 1) / threadsPerBlock;
#ifdef DEBUG
  cout << "[HMMLikeCUDA] Running with " << threadsPerBlock
       << " threads per block in " << blocksPerRun << " thread blocks\n";
#endif

  /*
    run kernel
  */
  findHapSet << <blocksPerRun, threadsPerBlock>>>
      (thrust::raw_pointer_cast(gd_packedGLs->data()),
       thrust::raw_pointer_cast(d_hapPanel.data()),
       thrust::raw_pointer_cast(d_hapIdxs.data()),
       thrust::raw_pointer_cast(d_extraPropHaps.data()),
       thrust::raw_pointer_cast(d_chosenHapIdxs.data()), numSamples, numCycles,
       devStates, thrust::raw_pointer_cast(gd_codeBook->data()), numSites
#ifdef DEBUG
       ,
       d_likePtr
#endif
       );
  cudaDeviceSynchronize();
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Failed to run HMM kernel: " << cudaGetErrorString(err) << "\n";
    exit(EXIT_FAILURE);
  }

  /*
    copy result hap indices back to host into hapIdxs
  */
  thrust::copy(d_chosenHapIdxs.begin(), d_chosenHapIdxs.end(), hapIdxs.begin());

  assert(cudaFree(devStates) == cudaSuccess);

#ifdef DEBUG
  thrust::host_vector<float> h_likes(numCycles + 1);
  h_likes = d_likes;

  // debug info
  cout << "Hap Idxs after sampling: ";
  for (int i = 0; i < hapIdxs.size(); ++i)
    cout << hapIdxs[i] << " ";
  cout << endl;

  cout << "cycle likelihoods: ";
  for (int i = 0; i < numCycles + 1; ++i)
    cout << h_likes[i] << " ";
  cout << endl;
#endif

  // return nothing as the return data is stored in hapIdxs
  return;
}
}
