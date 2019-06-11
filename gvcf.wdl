version 1.0

import "tasks/biopet/biopet.wdl" as biopet
import "tasks/common.wdl" as common
import "tasks/gatk.wdl" as gatk
import "tasks/picard.wdl" as picard
import "tasks/samtools.wdl" as samtools

workflow Gvcf {
    input {
        Array[IndexedBamFile] bamFiles
        String gvcfPath
        Reference reference
        IndexedVcfFile dbsnpVCF

        File? regions
        Int scatterSize = 10000000
        Map[String, String] dockerTags = {
          "samtools":"1.8--h46bd0b3_5",
          "picard":"2.18.26--0",
          "gatk4":"4.1.0.0--0",
          "biopet-scatterregions": "0.2--0",
          "tabix": "0.2.6--ha92aebf_0"
        }
    }

    String scatterDir = sub(gvcfPath, basename(gvcfPath), "scatters/")

    call biopet.ScatterRegions as scatterList {
        input:
            reference = reference,
            scatterSize = scatterSize,
            regions = regions,
            dockerTag = dockerTags["biopet-scatterregions"]
    }

    # Glob messes with order of scatters (10 comes before 1), which causes problems at gatherGvcfs
    call biopet.ReorderGlobbedScatters as orderedScatters {
        input:
            scatters = scatterList.scatters,
            # Dockertag not relevant here. Python script always runs in the same
            # python container.
    }

    scatter (f in bamFiles) {
        File files = f.file
        File indexes = f.index
    }

    scatter (bed in orderedScatters.reorderedScatters) {
        call gatk.HaplotypeCallerGvcf as haplotypeCallerGvcf {
            input:
                gvcfPath = scatterDir + "/" + basename(bed) + ".vcf.gz",
                intervalList = [bed],
                referenceFasta = reference.fasta,
                referenceFastaIndex = reference.fai,
                referenceFastaDict = reference.dict,
                inputBams = files,
                inputBamsIndex = indexes,
                dbsnpVCF = dbsnpVCF.file,
                dbsnpVCFIndex = dbsnpVCF.index,
                dockerTag = dockerTags["gatk4"]
        }

    }

    call picard.GatherVcfs as gatherGvcfs {
        input:
            inputVcfs = haplotypeCallerGvcf.outputGVCF,
            inputVcfIndexes = haplotypeCallerGvcf.outputGVCFIndex,
            outputVcfPath = gvcfPath,
            dockerTag = dockerTags["picard"]
    }

    call samtools.Tabix as indexGatheredGvcfs {
        input:
            inputFile = gatherGvcfs.outputVcf,
            outputFilePath = gvcfPath,
            dockerTag = dockerTags["tabix"]
    }

    output {
        IndexedVcfFile outputGVcf = object {
            file: indexGatheredGvcfs.indexedFile,
            index: indexGatheredGvcfs.index
        }
    }
}