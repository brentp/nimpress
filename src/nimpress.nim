import logging
import math
import strUtils

import docopt
import hts



################################################################################
## Utility functions
################################################################################

proc isNaN(x:float): bool =
  result = x.classify == fcNaN


proc tallyAlleles(rawDosages: seq[float]): (float, float, float) =
  # Tally the alleles in rawDosages, as returned by getRawDosages.  Returns
  # a tuple of three floats, with entries:
  #   number of samples with genotype
  #   number of samples missing genotype
  #   total count of effect allele in genotyped samples.
  var ngenotyped = 0.0
  var nmissing = 0.0
  var neffectallele = 0.0
  for dosage in rawDosages:
    if dosage.isNaN:
      nmissing += 1.0
    else:
      ngenotyped += 1.0
      neffectallele += dosage
  return (ngenotyped, nmissing, neffectallele)


proc binomTest(x: int, n: int, p: float): float =
  # Two-sided binomial test of observing x successes or more extreme in n 
  # trials, given success probability of p.  Returns the p value.
  # TODO: stub only atm
  result = 1.0



################################################################################
## Polygenic score file object
################################################################################

type ScoreFile = object
  # Really rough polygenic score file definition, just to get something working.  
  # Current format is 5 header lines followed by 6-column TSV.  Header lines 
  # are:
  #   name (string)
  #   description (string)
  #   citation (string)
  #   genome version (string)
  #   offset (string representation of float)
  # The subsequent TSV section is headerless, with one row per effect allele, 
  # columns:
  #   chrom, pos, ref, alt, beta, af
  # where beta is the PS coefficient and af the alt allele MAF in the source 
  # population.
  #
  # In future this should be a 'real' format (tabix-compatible? Will need to be 
  # space efficient if genome-wide scores are on the table).  
  fileobj: File
  name: string
  desc: string
  cite: string
  genomever: string
  offset: float


type ScoreEntry = tuple
  # Tuple container for ScoreFile records
  contig: string
  pos: int
  refseq: string
  altseq: string
  beta: float
  aaf: float


proc open(scoreFile: var ScoreFile, path: string): bool =
  # Open a ScoreFile
  scoreFile.fileobj = open(path)
  if scoreFile.fileobj.isNil:
    return false
  scoreFile.name = scoreFile.fileobj.readLine.strip(leading = false)
  scoreFile.desc = scoreFile.fileobj.readLine.strip(leading = false)
  scoreFile.cite = scoreFile.fileobj.readLine.strip(leading = false)
  scoreFile.genomever = scoreFile.fileobj.readLine.strip(leading = false)
  scoreFile.offset = scoreFile.fileobj.readLine.strip(leading = false).parseFloat
  return true


iterator items(scoreFile: ScoreFile): ScoreEntry =
  # Iterate over entries in scoreFile
  var line: string
  while scoreFile.fileobj.readLine(line):
    let lineparts = line.strip(leading = false).split('\t')
    doAssert lineparts.len == 6
    yield (lineparts[0], lineparts[1].parseInt, lineparts[2], lineparts[3], 
           lineparts[4].parseFloat, lineparts[5].parseFloat)



################################################################################
## Handling of well-genotyped regions
################################################################################

# TODO: Replace with a real interval search, returning true if 
# scoreEntry.chrom:scoreEntry.pos-(scoreEntry.pos+scoreEntry.ref.len-1) 
# is entirely in an interval of coveredBed, else false.
proc isVariantCovered(scoreEntry:ScoreEntry, coveredBed:File): bool =
  return true



################################################################################
## VCF access: variant search and dosage querying
################################################################################

proc findVariant(contig:string, pos:int, refseq:string, altseq:string, 
                 vcf:VCF): Variant =
  # Find contig:pos:refseq:altseq in vcf.  Returns the
  # whole VCF Variant if found, else nil.
  result = nil
  for variant in vcf.query(contig & ":" & $pos & "-" & $(pos + refseq.len - 1)):
    if variant.REF == refseq:
      for valt in variant.ALT:
        if valt == altseq:
          return variant


proc getRawDosages(rawDosages: var seq[float], variant:Variant, altseq:string) =
  # Get the dosages of altseq in the VCF Variant variant.  Returns
  # a sequence with values in {NaN, 0., 1., 2.}, being the dosage, or NaN
  # if no genotype is available.
  # TODO: Had trouble figuring out the best way to access the hts-nim API for
  # this.  Probably a much faster way to do it.  Not recreating the gts int32
  # seq each time seems like a good start.
  let altidx = find(variant.ALT, altseq)    # index of the desired alt allele
  var gts = newSeqUninitialized[int32](variant.n_samples)

  var i = 0
  for gt in genotypes(variant.format, gts):
    rawDosages[i] = 0.0
    for allele in gt:
      # +1 as altidx is a 0-based index into the alts, but value(allele) has the
      # first alt as 1.
      if value(allele) == altidx + 1:
        rawDosages[i] += 1
      elif value(allele) == -1:
        rawDosages[i] = NaN
    i += 1



################################################################################
## Imputation
################################################################################

# Locus and sample imputation methods:
# ps        Impute with dosage based on the polygenic score effect allele 
#           frequency.
# homref    Impute to homozygous reference genotype.
# fail      Do not impute, but fail. Failed samples will have a score of "nan"
# int_ps    Impute with dosage calculated from non-missing samples in the cohort.
#           At least --mincs non-missing samples must be available for this 
#           method to be used, else it will fall back to ps.
# int_fail  Impute with dosage calculated from non-missing samples in the cohort.
#           At least --mincs non-missing samples must be available for this 
#           method to be used, else it will fall back to fail.
type ImputeMethodLocus {.pure.} = enum ps, homref, fail
type ImputeMethodSample {.pure.} = enum ps, homref, fail, int_ps, int_fail


proc imputeLocusDosages(dosages: var seq[float], scoreEntry: ScoreEntry, 
                        imputeMethodLocus: ImputeMethodLocus) =
  # Impute all dosages at a locus.  Even non-missing genotypes are imputed.
  #
  # dosages: destination seq to which imputed dosages will be written.
  # scoreEntry: the polygenic score entry corresponding to this locus.
  # imputeMethodLocus: imputation method.
  let imputed_dosage = case imputeMethodLocus:
    of ImputeMethodLocus.ps:
      scoreEntry.aaf*2.0
    of ImputeMethodLocus.homref:
      0.0
    of ImputeMethodLocus.fail:
      NaN

  for i in 0..dosages.high:
    dosages[i] = imputed_dosage


proc imputeSampleDosages(dosages: var seq[float], scoreEntry: ScoreEntry, 
                         nEffectAllele: float, nGenotyped: float,
                         minGtForInternalImput: int, 
                         imputeMethodSample: ImputeMethodSample) =
  # Impute missing genotype dosages at a locus.  Genotypes which are not
  # missing will not be imputed.
  #
  # dosages: destination seq to which imputed dosages will be written.
  # scoreEntry: the polygenic score entry corresponding to this locus.
  # imputeMethodSample: imputation method.
  let imputed_dosage = case imputeMethodSample:
    of ImputeMethodSample.ps:
      scoreEntry.aaf*2.0
    of ImputeMethodSample.homref:
      0.0
    of ImputeMethodSample.fail:
      NaN
    of ImputeMethodSample.int_ps, ImputeMethodSample.int_fail:
      if nGenotyped >= minGtForInternalImput.toFloat:
        nEffectAllele / (2.0*nGenotyped)
      else:
        if imputeMethodSample == ImputeMethodSample.int_ps:
          scoreEntry.aaf*2.0
        else:
          NaN

  for i in 0..dosages.high:
    if dosages[i].isNaN:
      dosages[i] = imputed_dosage


proc getImputedDosages(dosages: var seq[float], scoreEntry: ScoreEntry, 
                       genotypeVcf: VCF, coveredBed: File,  
                       imputeMethodLocus: ImputeMethodLocus, 
                       imputeMethodSample: ImputeMethodSample,
                       maxMissingRate: float, afMismatchPthresh: float,
                       minGtForInternalImput: int) =
  # Fetch dosages of allele described in scoreEntry from samples genotyped in
  # genotypeVcf.  Impute dosages if necessary.
  #
  #   dosages: destination seq to which imputed dosages will be written.
  #   scoreEntry: the polygenic score entry corresponding to this locus.
  #   coveredBed: object containing genome regions which have been well-called
  #               (covered) by the genotyping method.
  #               TODO: Not implemented yet
  #   imputeMethodLocus: Imputation method to use when a whole locus fails or
  #                      is missing / not covered.
  #   imputeMethodSample: Imputation method to use for individual samples with
  #                       missing genotype, in a locus that passes QC filters.
  #   maxMissingRate: loci with more than this rate of missing samples fail
  #                   QC and are imputed.
  #   afMismatchPthresh: p-value threshold to warn about allele frequency 
  #                      mismatch between the cohort in genotypeVcf and the
  #                      polygenic score in scoreFile.
  #   minGtForInternalImput: Minimum number of genotyped samples at a locus for
  #                          internal imputation to be applied.
  let nsamples = genotypeVcf.n_samples
  dosages.setLen(nsamples)

  if not isVariantCovered(scoreEntry, coveredBed):
    log(lvlWarn, "Locus " & scoreEntry.contig & ":" & $scoreEntry.pos & "-" & 
        $(scoreEntry.pos + scoreEntry.refseq.len - 1) & 
        " is not covered by the sequence coverage BED.  Imputing all dosages " &
        "at this locus.")
    imputeLocusDosages(dosages, scoreEntry, imputeMethodLocus)
    return

  let variant = findVariant(scoreEntry.contig, scoreEntry.pos, 
                            scoreEntry.refseq, scoreEntry.altseq, genotypeVcf)

  if variant.isNil:
    if binomTest(0, nsamples*2, scoreEntry.aaf) < afMismatchPthresh:
      log(lvlWarn, "Variant " & scoreEntry.contig & ":" & $scoreEntry.pos & 
          ":" & $scoreEntry.refseq & ":" & $scoreEntry.altseq & 
          " cohort AAF is 0 in " & $nsamples & ".  This is highly unlikely " & 
          "given polygenic score AAF of " & $scoreEntry.aaf)
    # Set all dosages to zero and return
    for i in 0..dosages.high:
      dosages[i] = 0.0
    return

  if $variant.FILTER != "." and $variant.FILTER != "PASS":
    log(lvlWarn, "Variant " & scoreEntry.contig & ":" & $scoreEntry.pos & ":" & 
        $scoreEntry.refseq & ":" & $scoreEntry.altseq & 
        " has a FILTER flag set (value \"" & $variant.FILTER & "\").  " & 
        "Imputing all dosages at this locus.")
    imputeLocusDosages(dosages, scoreEntry, imputeMethodLocus)
    return

  # Fetch the raw dosages (values in {NaN, 0., 1., 2.}) from the VCF.
  getRawDosages(dosages, variant, scoreEntry.altseq)

  let (ngenotyped, nmissing, neffectallele) = tallyAlleles(dosages)
  
  let missingrate = nmissing / nsamples.toFloat
  if missingrate > maxMissingRate:
    log(lvlWarn, "Locus " & scoreEntry.contig & ":" & $scoreEntry.pos & "-" & 
        $(scoreEntry.pos + scoreEntry.refseq.len - 1) & " has " & 
        $(missingrate*100) & "% of samples missing a genotype. This exceeds " &
        "the missingness threshold; imputing all dosages at this locus.")
    imputeLocusDosages(dosages, scoreEntry, imputeMethodLocus)
    return

  if binomTest(neffectallele.toInt, nsamples*2, scoreEntry.aaf) < afMismatchPthresh:
    log(lvlWarn, "Variant " & scoreEntry.contig & ":" & $scoreEntry.pos & 
        ":" & $scoreEntry.refseq & ":" & $scoreEntry.altseq & 
        " cohort AAF is " & $(neffectallele/(nsamples*2).toFloat) & 
        " in " & $nsamples & ".  This is highly unlikely given polygenic " &
        "score AAF of " & $scoreEntry.aaf)

  # Impute single missing sample dosages
  imputeSampleDosages(dosages, scoreEntry, neffectallele, ngenotyped, 
                      minGtForInternalImput, imputeMethodSample)



################################################################################
## Polygenic score calculation
################################################################################

proc computePolygenicScores(scores: var seq[float], scoreFile: ScoreFile, 
                            genotypeVcf: VCF, coveredBed: File, 
                            imputeMethodLocus: ImputeMethodLocus, 
                            imputeMethodSample: ImputeMethodSample,
                            maxMissingRate: float, afMismatchPthresh: float,
                            minGtForInternalImput: int) =
  # Compute polygenic scores.
  #
  #   scores: seq[float] to which the scores will be written. Will be resized to
  #           the number of samples in genotypeVcf.
  #   scoreFile: an open ScoreFile describing the polygenic score.
  #   genotypeVcf: an open VCF containing genotypes of samples for which to
  #                calculate scores.
  #   coveredBed: object containing genome regions which have been well-called
  #               (covered) by the genotyping method.
  #               TODO: Not implemented yet
  #   imputeMethodLocus: Imputation method to use when a whole locus fails or
  #                      is missing / not covered.
  #   imputeMethodSample: Imputation method to use for individual samples with
  #                       missing genotype, in a locus that passes QC filters.
  #   maxMissingRate: loci with more than this rate of missing samples fail
  #                   QC and are imputed.
  #   afMismatchPthresh: p-value threshold to warn about allele frequency 
  #                      mismatch between the cohort in genotypeVcf and the
  #                      polygenic score in scoreFile.
  #   minGtForInternalImput: Minimum number of genotyped samples at a locus for
  #                          internal imputation to be applied.
  let nsamples = genotypeVcf.n_samples

  # Initialise the scores to the offset term
  scores.setLen(nsamples)
  for i in 0..scores.high:
    scores[i] = scoreFile.offset

  # Iterate over PS loci.  For each locus, get its (possibly imputed) dosages,
  # and add its score contribution to the accumulating scores.
  var nloci = 0
  var dosages = newSeqUninitialized[float](nsamples)
  for scoreEntry in scoreFile:
    getImputedDosages(dosages, scoreEntry, genotypeVcf, coveredBed, 
                      imputeMethodLocus, imputeMethodSample, maxMissingRate, 
                      afMismatchPthresh, minGtForInternalImput)
    for i in 0..scores.high:
      scores[i] += dosages[i] * scoreEntry.beta
    nloci += 1

  # Average over the PRS loci to match PLINK behaviour
  for i in 0..scores.high:
    scores[i] /= nloci.toFloat



proc main() = 
  let doc = """
  Compute polygenic scores from a VCF/BCF.

  Usage:
    nimpress [options] <scoredef> <genotypes.vcf>
    nimpress (-h | --help)
    nimpress --version

  Options:
    -h --help         Show this screen.
    --version         Show version.
    --cov=<path>      Path to a BED file supplying genome regions that have been
                      genotyped in the genotypes.vcf file.
    --imp-locus=<m>   Imputation to apply for whole loci which are either not
                      in the sequenced BED regions, or fail (QUAL flag or too
                      many samples with missing genotype). Valid values are ps, 
                      homref, fail [default: ps].
    --imp-sample=<m>  Imputation to apply for an individual sample with missing 
                      genotype. Valid values are ps, homref, fail, int_fail, 
                      int_ps [default: int_ps].
    --maxmis=<f>      Maximum fraction of samples with missing genotypes allowed
                      at a locus.  Loci containing more than this fraction of 
                      samples missing will be considered bad, and have all 
                      genotypes (even non-missing ones) imputed [default: 0.05].
    --mincs=<n>       Minimum number of genotypes.vcf samples without missing 
                      genotype at a locus for this locus to be eligible for 
                      internal imputation [default: 100].
    --afmisp=<f>      p-value threshold for warning about allele frequency 
                      mismatch between the polygenic score and the supplied 
                      cohort [default: 0.001].

  Imputation methods:
  ps        Impute with dosage based on the polygenic score effect allele 
            frequency.
  homref    Impute to homozygous reference genotype.
  fail      Do not impute, but fail. Failed samples will have a score of "nan"
  int_ps    Impute with dosage calculated from non-missing samples in the 
            cohort. At least --mincs non-missing samples must be available for 
            this method to be used, else it will fall back to ps.
  int_fail  Impute with dosage calculated from non-missing samples in the 
            cohort. At least --mincs non-missing samples must be available for 
            this method to be used, else it will fall back to fail.
  """

  let args = docopt(doc, version = "nimpress 0.0.1")

  var consoleLog = newConsoleLogger()
  addHandler(consoleLog)

  let
    maxMissingRate = parseFloat($args["--maxmis"])
    afMismatchPthresh = parseFloat($args["--afmisp"])
    minInternalImputeCohortSize = parseInt($args["--mincs"])
    imputeMethodLocus = parseEnum[ImputeMethodLocus]($args["--imp-locus"])
    imputeMethodSample = parseEnum[ImputeMethodSample]($args["--imp-sample"])

  var genotypeVcf:VCF
  var scoreFile:ScoreFile
  var coveredBed:File

  if not open(genotypeVcf, $args["<genotypes.vcf>"]):
    log(lvlFatal, "Could not open input VCF file " & $args["<genotypes.vcf>"])

  if not open(scoreFile, $args["<scoredef>"]):
    log(lvlFatal, "Could not open polygenic score file " & $args["<scoredef>"])

  if args["--cov"]:
    log(lvlFatal, "Coverage BED currently not supported.")

  var scores = newSeqUninitialized[float](0)   # Will be resized as needed
  computePolygenicScores(scores, scoreFile, genotypeVcf, coveredBed, 
                         imputeMethodLocus, imputeMethodSample,
                         maxMissingRate, afMismatchPthresh, 
                         minInternalImputeCohortSize)

  for i in 0..scores.high:
    echo $samples(genotypeVcf)[i] & "\t" & $scores[i]


when isMainModule:
  main()

