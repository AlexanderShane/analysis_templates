# get local variables
source local.env

## two positional arguments specifying 1) the directory containing fastqs in samplewise subfolders a la download_SRA.sh, and 2) the output analysis directory
indir=$1
outdir=$2

mkdir -p ${outdir}/01_BBDuk/logs
mkdir ${outdir}/01_BBDuk/trimmed

samples=($(grep SRR ${indir}/runInfo.csv | grep 'WGA\|WGS\|RNA-Seq' | cut -d ',' -f 1))

cat <<EOF > ${outdir}/01_BBDuk/01_BBDuk.sbatch
#!/bin/bash
#SBATCH --qos=rra
#SBATCH --partition=rra
#SBATCH --time=6-00:00:00
#SBATCH --mem=${maxram}
#SBATCH --job-name=01_BBDuk
#SBATCH --output=${outdir}/01_BBDuk/logs/01_BBDuk%a.log
#SBATCH --array=0-$((${#samples[@]}-1))%10

samples=(${samples[@]})
sample=\${samples[\$SLURM_ARRAY_TASK_ID]} ## each array job has a different sample

module purge
module load hub.apps/anaconda3
source /shares/omicshub/apps/anaconda3/etc/profile.d/conda.sh
conda deactivate
conda deactivate
source activate bbtools

in1=(${indir}/*/\${sample}/\${sample}_1.fastq.gz)
in2=(${indir}/*/\${sample}/\${sample}_2.fastq.gz)

out1=${outdir}/01_BBDuk/trimmed/\${sample}_1.fastq
out2=${outdir}/01_BBDuk/trimmed/\${sample}_2.fastq

## trim the 3' ends of reads based on quality scores
## use 23-mers to identify adapters and artifacts
## trim both 5' and 3' ends of reads based on matches to sequencing adapters and artifacts
## default length of a single kmer downstream; if a read is trimmed shorter than this just discard it
## trim reads once they reach quality scores of 20 (for de-kupl I think it may pay to be stringent here; maybe even more than 20)
bbduk.sh \
  in1=\${in1} \
  in2=\${in2} \
  out1=\${out1} \
  out2=\${out2} \
  ref=adapters,artifacts \
  qtrim=r \
  ktrim=rl \
  k=23 \
  mink=11 \
  hdist=2 \
  minlength=31 \
  trimq=20 

gzip --best -c \${out1} > \${out1/.fastq/.fastq.gz}
gzip --best -c \${out2} > \${out2/.fastq/.fastq.gz}

rm \${out1}
rm \${out2}

EOF

if $autorun; then
    sbatch ${outdir}/01_BBDuk/01_BBDuk.sbatch
fi
