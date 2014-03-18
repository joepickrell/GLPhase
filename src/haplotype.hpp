/* @(#)haplotype.hpp
 */

#ifndef _HAPLOTYPE_H
#define _HAPLOTYPE_H 1

#include <vector>
#include <stdint.h>
#include <cmath>
#include <assert.h>

// require c++11
static_assert(__cplusplus > 199711L, "Program requires C++11 capable compiler");

#define h_WordMod 63  // word size -1
#define h_WordShift 6 // 2^6 = 64

class Haplotype {

private:
  std::vector<uint64_t> m_utHap;

public:
  unsigned m_uNumAlleles;

  // initialize all haps to all 0s
  Haplotype(unsigned uNumAlleles) : m_uNumAlleles(uNumAlleles) {
    unsigned uSize = ceil(static_cast<float>(uNumAlleles) /
                          static_cast<float>(h_WordMod + 1));
    m_utHap.reserve(uSize);
    for (unsigned uWord = 0; uWord < uSize; uWord++)
      m_utHap.push_back(static_cast<uint64_t>(0));
  }

  // site is 0 based site number to be set
  // allele is either 1 or 0 and is the bit to set the site to
  void Set(unsigned uSite, bool bAllele);

  bool TestSite(unsigned uSite) const {
    assert(uSite < m_uNumAlleles);
    return (m_utHap[uSite >> h_WordShift] >> (uSite & h_WordMod)) &
           static_cast<uint64_t>(1);
  };

  // test if bit uSite is 1
  uint64_t TestSite(unsigned uSite, const uint64_t *P) const {
    return (P[uSite >> h_WordShift] >> (uSite & h_WordMod)) &
           static_cast<uint64_t>(1);
  };

  uint64_t GetWord(unsigned uWordNum) const {
    return m_utHap[uWordNum];
  };

  // using a haplotype object
  unsigned HammingDist(const Haplotype &oCompareHap) const;

  // using a vector pointer
  unsigned HammingDist(const uint64_t *upHap) const;

  unsigned HammingDist(const uint64_t *upHap1, const uint64_t *upHap2) const;

  // calculate the max shared tract length like B.Howie
  // using a haplotype object
  unsigned MaxTractLen(const Haplotype &compHap) const;
};

#endif /* _HAPLOTYPE_H */
