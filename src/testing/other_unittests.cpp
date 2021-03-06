
#include "gtest/gtest.h"
#include "haplotype.hpp"
#include "kNN.hpp"
#include "MHSampler.hpp"
#include "geneticMap.hpp"
#include "bio.hpp"
#include <algorithm>
#include <gsl/gsl_rng.h>
#include <utility>

using namespace std;

string sampleDir = "../../samples";
string brokenDir = sampleDir + "/brokenFiles";
string sampleLegend =
    sampleDir + "/20_011976121_012173018.bin.onlyThree.legend";
string sampleHap = sampleDir + "/20_011976121_012173018.bin.onlyThree.hap";
string sampleBin = sampleDir + "/20_011976121_012173018.bin.onlyThree.bin";
string sampleBase = sampleDir + "/20_011976121_012173018.bin.onlyThree";
string refHap =
    sampleDir + "/20_0_62000000.011976121_012173018.paste.onlyThree.hap";
string refLegend =
    sampleDir + "/20_0_62000000.011976121_012173018.paste.onlyThree.legend";
string refHaps =
    sampleDir + "/20_0_62000000.011976121_012173018.paste.onlyThree.haps";

string brokenHapLegSampSample =
    brokenDir + "/onlyThree.hapLegSample.extraLine.sample";
string brokenHapsSampSample =
    brokenDir + "/onlyThree.hapsSample.extraLine.sample";
string unsortedRefHaps =
    sampleDir +
    "/20_0_62000000.011976121_012173018.paste.onlyThree.unsorted.haps";
string geneticMap =
    sampleDir + "/geneticMap/genetic_map_chr20_combined_b37.txt.gz";

gsl_rng *rng = gsl_rng_alloc(gsl_rng_default);

TEST(Haplotype, StoresOK) {

  // testing to see if init and testing works ok
  Haplotype simpleA(4);

  for (unsigned i = 0; i < 4; i++)
    EXPECT_FALSE(simpleA.TestSite(i));

  EXPECT_DEATH(simpleA.TestSite(4), "uSite < m_uNumAlleles");

  Haplotype simpleB(4);
  simpleB.Set(0, 1);
  simpleB.Set(3, 1);
  EXPECT_TRUE(simpleB.TestSite(0));
  EXPECT_TRUE(simpleB.TestSite(3));
  EXPECT_FALSE(simpleB.TestSite(2));

  // test hamming distance
  EXPECT_EQ(2, simpleA.HammingDist(simpleB));
  EXPECT_EQ(0, simpleA.HammingDist(simpleA));

  Haplotype longA(128);
  Haplotype longB(128);

  EXPECT_DEATH(simpleA.Set(128, 1), "uSite < m_uNumAlleles");
  EXPECT_DEATH(simpleA.TestSite(128), "uSite < m_uNumAlleles");

  longA.Set(127, 1);
  longA.Set(1, 1);
  EXPECT_EQ(2, longA.HammingDist(longB));
  EXPECT_EQ(2, longB.HammingDist(longA));
  longB.Set(120, 1);
  EXPECT_EQ(3, longB.HammingDist(longA));

  vector<uint64_t> hapWords;
  hapWords.push_back(longA.GetWord(0));
  ASSERT_TRUE(longB.TestSite(1, hapWords.data()));
}

// testing the max tract length measure
TEST(Haplotype, tractLenOK) {

  Haplotype simpleA(4);
  EXPECT_EQ(4, simpleA.MaxTractLen(simpleA));

  Haplotype simpleB(4);
  simpleB.Set(0, 1);
  simpleB.Set(3, 1);

  EXPECT_EQ(2, simpleA.MaxTractLen(simpleB));

  Haplotype simpleC(1024);
  EXPECT_EQ(1024, simpleC.MaxTractLen(simpleC));

  Haplotype simpleD(1024);
  simpleD.Set(23, 1);
  EXPECT_EQ(1000, simpleC.MaxTractLen(simpleD));
  EXPECT_EQ(1000, simpleD.MaxTractLen(simpleC));

  simpleD.Set(1023, 1);
  EXPECT_EQ(999, simpleD.MaxTractLen(simpleC));
}

TEST(KNN, clustersOK) {

  gsl_rng_set(rng, time(NULL));
  std::srand(1);

  // testing to see if nearest neighbor clustering works ok
  unsigned numClusters = 4;
  unsigned numHaps = 16;
  unsigned numSites = numHaps + numClusters * 2;

  // create a set of test haplotypes to cluster and sample from
  vector<Haplotype> haplotypes;
  vector<unsigned> shuffledIndexes(numHaps);

  for (unsigned i = 0; i < numHaps; i++) {
    shuffledIndexes[i] = i;
    Haplotype temp(numSites);

    for (unsigned j = 0; j < numClusters + 2; j++)
      temp.Set(i + j, 1);

    haplotypes.push_back(temp);
  }

  // make the second haplotype match hap number 16 and 15 (0 based) closest
  // but not as well as hap 0 would match hap 4
  for (unsigned i = numSites - 6; i < numSites; i++) {
    haplotypes[1].Set(i - numSites + 7, false);
    haplotypes[1].Set(i, true);
  }

  // shuffle the haplotypes except for the first two
  std::random_shuffle(shuffledIndexes.begin() + 2, shuffledIndexes.end());

  vector<uint64_t> passHaps;

  for (unsigned j = 0; j < shuffledIndexes.size(); j++)
    passHaps.push_back(haplotypes[shuffledIndexes[j]].GetWord(0));

  /*  for (unsigned idx = 0; idx != haplotypes.size(); idx++) {
      cerr << idx << ": ";

      for (unsigned i = 0; i < numSites; i++)
        cerr << haplotypes[shuffledIndexes[idx]].TestSite(i);

      cerr << endl;
      }*/

  KNN kNN(numClusters, passHaps, 1, numSites, 0, 1, false, rng);

  // check to make sure kNN has the haps stored correctly
  vector<unsigned> neighborHapNums = kNN.Neighbors(0);

  EXPECT_EQ(numClusters, neighborHapNums.size());
  EXPECT_EQ(2, shuffledIndexes[neighborHapNums[0]]);
  EXPECT_EQ(15, shuffledIndexes[neighborHapNums[1]]);
  EXPECT_EQ(3, shuffledIndexes[neighborHapNums[2]]);
  EXPECT_EQ(14, shuffledIndexes[neighborHapNums[3]]);

  // testing sampling
  for (unsigned i = 0; i < 10; i++) {
    unsigned sampHap = kNN.SampleHap(0);
    EXPECT_LT(shuffledIndexes[sampHap], numHaps);
    EXPECT_GT(shuffledIndexes[sampHap], 1);

    for (unsigned i = 4; i < numHaps - 2; i++)
      EXPECT_NE(shuffledIndexes[sampHap], i);
  }

  // undo change of hap 1
  for (unsigned i = numSites - 6; i < numSites; i++) {
    haplotypes[1].Set(i - numSites + 7, true);
    haplotypes[1].Set(i, false);
  }

  // now test the thresholding option
  // first site above threshold
  haplotypes[1].Set(0, true);
  haplotypes[5].Set(0, true);
  haplotypes[6].Set(0, true);
  haplotypes[8].Set(0, true);
  haplotypes[9].Set(0, true);
  haplotypes[10].Set(0, true);

  // second site above threshold
  haplotypes[5].Set(2, true);
  haplotypes[6].Set(2, true);
  haplotypes[8].Set(2, true);
  haplotypes[11].Set(2, true);
  haplotypes[12].Set(2, true);

  haplotypes[0].Set(numSites - 1, true);
  haplotypes[1].Set(numSites - 1, true);
  haplotypes[5].Set(numSites - 1, true);
  haplotypes[7].Set(numSites - 1, true);
  haplotypes[15].Set(numSites - 1, true);
  haplotypes[14].Set(numSites - 1, true);
  haplotypes[13].Set(numSites - 1, true);

  haplotypes[0].Set(numSites - 2, true);
  haplotypes[1].Set(numSites - 2, true);
  haplotypes[2].Set(numSites - 2, true);
  haplotypes[3].Set(numSites - 2, true);
  haplotypes[4].Set(numSites - 2, true);
  haplotypes[5].Set(numSites - 2, true);
  haplotypes[8].Set(numSites - 2, true);

  /*    for(auto hap : haplotypes){
          for(unsigned i = 0; i < numSites; i++)
              cerr << hap.TestSite(i);
          cerr << endl;
          }*/

  passHaps.clear();

  for (unsigned j = 0; j < shuffledIndexes.size(); j++)
    passHaps.push_back(haplotypes[shuffledIndexes[j]].GetWord(0));

  KNN kNN2(numClusters, passHaps, 1, numSites, 0.4375, 1, false, rng);

  // check to make sure variant allele freqs are calculated correctly
  vector<double> varAfs;
  kNN2.VarAfs(varAfs);
  EXPECT_EQ(numSites, varAfs.size());
  EXPECT_EQ(0.4375, varAfs[0]);
  EXPECT_EQ(0.125, varAfs[1]);
  EXPECT_EQ(0.5, varAfs[2]);

  // check to make sure kNN is thresholding the correct sites
  vector<unsigned> commonSites;
  kNN2.ClusterSites(commonSites);
  EXPECT_EQ(4, commonSites.size());

  // check to make sure kNN has the haps stored correctly
  neighborHapNums = kNN2.Neighbors(0);

  EXPECT_EQ(numClusters, neighborHapNums.size());
  EXPECT_EQ(5, shuffledIndexes[neighborHapNums[0]]);
  EXPECT_EQ(6, shuffledIndexes[neighborHapNums[1]]);
  EXPECT_EQ(8, shuffledIndexes[neighborHapNums[2]]);
  EXPECT_EQ(2, shuffledIndexes[neighborHapNums[3]]);

  // testing sampling
  for (unsigned i = 0; i < 10; i++) {
    unsigned sampHap = kNN2.SampleHap(0);
    EXPECT_LT(shuffledIndexes[sampHap], 9);
    EXPECT_GT(shuffledIndexes[sampHap], 1);
    EXPECT_NE(shuffledIndexes[sampHap], 3);
    EXPECT_NE(shuffledIndexes[sampHap], 4);
    EXPECT_NE(shuffledIndexes[sampHap], 7);
  }
}

TEST(MHSampler, MHSamplesOK) {

  gsl_rng_set(rng, time(NULL));

  double curr = -100;
  unsigned hapNum = 1;
  MHSampler<unsigned> mhSampler(rng, curr, MHType::MH);

  // testing MH sampler always returns better val if like is better
  for (unsigned i = 2; i < 10; ++i) {
    hapNum = i;
    EXPECT_TRUE(mhSampler.SampleHap(hapNum, i - 1, curr + i * 0.01));
    EXPECT_EQ(i, hapNum);
  }

  // testing MH sampler sometimes returns worse val if like is worse
  for (unsigned i = 0; i < 100; ++i) {
    unsigned prevVal = hapNum;
    hapNum = 10;
    mhSampler.SampleHap(hapNum, prevVal, curr);
  }
  EXPECT_EQ(10, hapNum);

  // testing MH sampler rarely returns worse val if like is much worse
  hapNum = 11;
  EXPECT_FALSE(mhSampler.SampleHap(hapNum, 10, 2 * curr));
  EXPECT_EQ(10, hapNum);
}

TEST(MHSampler, DRMHSamplesOK) {

  gsl_rng_set(rng, time(NULL));

  double curr = -100;
  unsigned hapNum = 1;
  MHSampler<unsigned> mhSampler(rng, curr, MHType::DRMH);

  // testing DRMH sampler always returns better val if like is better
  for (unsigned i = 2; i < 10; ++i) {
    unsigned prevVal = hapNum;
    hapNum = i;
    EXPECT_TRUE(mhSampler.SampleHap(hapNum, prevVal, curr + i * 0.01));
    EXPECT_EQ(i, hapNum);
  }

  // testing DRMH sampler always returns better val if
  // second like is worse, but third like is better
  hapNum = 10;
  EXPECT_FALSE(mhSampler.SampleHap(hapNum, 9, 2 * curr));
  EXPECT_EQ(10, hapNum);
  ++hapNum;
  EXPECT_TRUE(mhSampler.SampleHap(hapNum, 10, curr + 11 * 0.01));
  EXPECT_EQ(11, hapNum);

  // testing DRMH sampler always returns first val if
  // second like is worse, but third like is even worse
  hapNum = 12;
  EXPECT_FALSE(mhSampler.SampleHap(hapNum, 11, 2 * curr));
  EXPECT_EQ(12, hapNum);
  ++hapNum;
  EXPECT_FALSE(mhSampler.SampleHap(hapNum, 12, 3 * curr));
  EXPECT_EQ(11, hapNum);

  // testing DRMH sampler rarely returns second val if
  // first is worse, but second is only slightly better
  hapNum = 13;
  EXPECT_FALSE(mhSampler.SampleHap(hapNum, 11, 2 * curr));
  EXPECT_EQ(13, hapNum);
  hapNum = 14;
  EXPECT_FALSE(mhSampler.SampleHap(hapNum, 13, 1.99 * curr));
  EXPECT_EQ(11, hapNum);
}

TEST(MHSampler, DRMHSamplesArrayOK) {

  gsl_rng_set(rng, time(NULL));

  double curr = -100;
  unsigned hapNums[4];
  for (unsigned i = 0; i < 4; ++i)
    hapNums[i] = i + 4;
  MHSampler<unsigned> mhSampler(rng, curr, MHType::DRMH);

  // testing DRMH sampler always returns better val if like is better
  for (unsigned i = 2; i < 10; ++i) {
    unsigned prevVal = hapNums[3];
    hapNums[3] = i;
    EXPECT_TRUE(mhSampler.SampleHap(hapNums[1], prevVal, curr + i * 0.01));
    EXPECT_EQ(i, hapNums[3]);
    for (unsigned i = 0; i < 3; ++i)
      EXPECT_EQ(i + 4, hapNums[i]);
  }

  // testing DRMH sampler always returns better val if
  // second like is worse, but third like is better
  hapNums[3] = 10;
  EXPECT_FALSE(mhSampler.SampleHap(hapNums[3], 9, 2 * curr));
  EXPECT_EQ(10, hapNums[3]);
  hapNums[0] = 0;
  EXPECT_TRUE(mhSampler.SampleHap(hapNums[0], 4, curr + 11 * 0.01));
  EXPECT_EQ(0, hapNums[0]);
  EXPECT_EQ(10, hapNums[3]);

  // testing DRMH sampler always returns first state if
  // second like is worse, but third like is even worse
  hapNums[0] = 4;
  hapNums[3] = 12;
  EXPECT_FALSE(mhSampler.SampleHap(hapNums[3], 10, 2 * curr));
  EXPECT_EQ(12, hapNums[3]);
  hapNums[0] = 0;
  EXPECT_FALSE(mhSampler.SampleHap(hapNums[0], 4, 3 * curr));
  EXPECT_EQ(10, hapNums[3]);
  EXPECT_EQ(4, hapNums[0]);

  // testing DRMH sampler rarely returns second val if
  // first is worse, but second is only slightly better
  hapNums[0] = 4;
  hapNums[3] = 12;
  EXPECT_FALSE(mhSampler.SampleHap(hapNums[3], 10, 2 * curr));
  EXPECT_EQ(12, hapNums[3]);
  hapNums[0] = 0;
  EXPECT_FALSE(mhSampler.SampleHap(hapNums[0], 4, 1.99 * curr));
  EXPECT_EQ(10, hapNums[3]);
  EXPECT_EQ(4, hapNums[0]);
}

TEST(GeneticMap, errorOK) {

  GeneticMap gmap(geneticMap);
  ASSERT_ANY_THROW(gmap.GeneticDistance(1140749, 1140727));  // order ok
  ASSERT_ANY_THROW(gmap.GeneticDistance(0, 1140727));        // out of bounds
  ASSERT_ANY_THROW(gmap.GeneticDistance(1140727, 70000000)); // out of bounds
}

TEST(GeneticMap, locationOK) {

  GeneticMap gmap(geneticMap);
  EXPECT_DOUBLE_EQ(5.49294973985857, gmap.GeneticLocation(1140749));
  EXPECT_DOUBLE_EQ(5.49294697413266, gmap.GeneticLocation(1140727));
  EXPECT_DOUBLE_EQ(5.49294697413266 +
                       (5.49294973985857 - 5.49294697413266) * 3 / 22,
                   gmap.GeneticLocation(1140730));
}

TEST(GeneticMap, distanceOK) {

  GeneticMap gmap(geneticMap);
  // no interpolation
  EXPECT_DOUBLE_EQ((5.49294973985857 - 5.49294697413266) / 100,
                   gmap.GeneticDistance(1140727, 1140749));
  EXPECT_DOUBLE_EQ(0.0549294697413266, gmap.GeneticDistance(61795, 1140727));
  EXPECT_DOUBLE_EQ(1.10205396293913, gmap.GeneticDistance(61795, 62949445));
  EXPECT_DOUBLE_EQ(1.0471244931978034, gmap.GeneticDistance(1140727, 62949445));

  // interpolation of one site
  EXPECT_NEAR((5.49294973985857 - 5.49294697413266) / 22 * 5 / 100,
              gmap.GeneticDistance(1140727, 1140732), 1e-9);
  EXPECT_NEAR(((5.49294697413266 - 5.49291291069285) / 270 * 220 +
               (5.49294973985857 - 5.49294697413266) / 22 * 5) /
                  100,
              gmap.GeneticDistance(1140507, 1140732), 1e-8);
}
