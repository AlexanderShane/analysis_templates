## get user-edited environmental variables outdir, counts_fp, etc
args <- commandArgs(TRUE)

load(args[[1]])
load(args[[2]])
samplenames <- read.table(args[[3]],sep='\t',header=T)
metadat <- read.table(args[[4]],sep='\t',header=T)
id_conversion <- read.table(args[[5]],sep='\t',header=T)

outdir <- args[[6]]
K_s <- as.numeric(args[[7]])
K_f <- as.numeric(args[[8]])
nchains <- as.numeric(args[[9]])
nthreads <- as.numeric(args[[10]])
opencl <- as.logical(args[[11]])
opencl_device <- as.numeric(args[[12]])
model_dir <- args[[13]]

##

rownames(seqtab) <- sapply(rownames(seqtab), function(x) samplenames$Sample[samplenames$Tag == sub('.fastq.gz','',sub('-',':',x))])

seqtab_F <- seqtab[grep('UFL',rownames(seqtab)),]

seqtab_M <- t(sapply(unique(sub('_.*','',rownames(seqtab_F))), function(x) apply(seqtab_F[grep(x,rownames(seqtab_F)),], 2, sum)))

metadat$id_argaly <- id_conversion$id_argaly[match(metadat$ID..Alison, id_conversion$id_alison)]

m2 <- metadat[match(rownames(seqtab_M),metadat$id_argaly),]

dna <- Biostrings::DNAStringSet(dada2::getSequences(seqtab))
ids <- DECIPHER::IdTaxa(dna, trainingSet, strand="top", processors=NULL, verbose=FALSE) 
ranks <- c("domain", "phylum", "class", "order", "family", "genus", "species") 
# Convert the output object of class "Taxa" to a matrix analogous to the output from assignTaxonomy
taxid <- t(sapply(ids, function(x) {
  m <- match(ranks, x$rank)
  taxa <- x$taxon[m]
  taxa[startsWith(taxa, "unclassified_")] <- NA
  taxa
}))
colnames(taxid) <- ranks; rownames(taxid) <- dada2::getSequences(seqtab)

## set up output directory
dir.create(file.path(outdir, '03_zip'))
##

counts <- t(seqtab_M)
counts <- counts[order(apply(apply(counts, 2, function(x) x / sum(x)),1,sum), decreasing=T), 
                 order(apply(counts,2,sum), decreasing = T)]
relabund <- apply(counts, 2, function(x) x / sum(x))

countsbin <- t(as.matrix(counts))
countsbin[countsbin > 0] <- 1

countsmod <- t(as.matrix(counts))
countsmod[countsmod==0] <- 0.5
logcountsmod <- log(countsmod)

rownames(m2) <- m2$id_argaly
m2 <- m2[colnames(counts)[colnames(counts) %in% rownames(m2)],]
m2$Location <- as.factor(m2$Location)

NS    = ncol(counts)
NF    = nrow(counts)

X_s <- cbind(Intercept=1, model.matrix(~ 0 + Location, m2)) ## standardize continuous variables before placing in model
X_s[,-1] <- apply(X_s[,-1], 2, function(x) x - mean(x))
rownames(X_s) <- rownames(m2)
X_s <- X_s[colnames(counts),]

idx_s <- c(1, rep(2, nlevels(m2$Location)))
NSB <- max(idx_s)
NB_s <- length(idx_s)

## work on this section to make sure columns are unique and so that taxa are filtered out if they apply to ALL samples as well as none
hi <- cbind('Intercept',unique(taxid))

estimables <- lapply(2:(ncol(hi)-1), function(x) {
  y <- unique(hi[,1:x])
  keepers <- apply(y, 1, function(z) sum(apply(y[,1:(x-1),drop=F],1, function(r) identical(z[1:(x-1)],r))) > 1 & !is.na(z[[x]]))
  return(unname(y[keepers,x]))
})

X_f <- cbind(Intercept=1, do.call(cbind, sapply(1:length(estimables), function(x) sapply(estimables[[x]], function(y) as.numeric(taxid[,x] == y)))))
rownames(X_f) <- rownames(taxid)
X_f[is.na(X_f)] <- 0
X_f[,-1] <- apply(X_f[,-1], 2, function(x) x-mean(x))
X_f <- X_f[rownames(counts),]
##

idx_f = c(1, rep(2, ncol(X_f)-1))
NFB   = max(idx_f)
NB_f  = length(idx_f)

prior_scale_p <- sqrt(exp(mean(log(apply(countsbin,2,var)[apply(countsbin,2,var) > 0]))))
prior_scale_a <- sqrt(exp(mean(log(apply(counts,2,function(x) var(log(x[x>0])))))))


standat <- list(NS            = NS,
                NB_s          = NB_s,
                NSB           = NSB,
                idx_s         = idx_s,
                X_s           = X_s,
                NF            = NF,
                NB_f          = NB_f,
                NFB           = NFB,
                idx_f         = idx_f,
                X_f           = t(X_f),
                count         = counts,
                prior_scale_a = prior_scale_a,
                prior_scale_p = prior_scale_p,
                K_s           = K_s,
                K_f           = K_f)

save.image(file.path(outdir, '03_zip', 'zip_glm_setup.RData'))

cmdstanr::write_stan_json(standat, file.path(outdir, '03_zip', 'zip_test_data.json'))

setwd(cmdstanr::cmdstan_path())
system(paste0(c('make ', 'make STAN_OPENCL=true ')[opencl+1], file.path(model_dir,'zip_glm')))

sampling_commands <- list(hmc = paste('./zip_glm',
                                      paste0('data file=',path.expand(file.path(outdir, '03_zip', 'zip_test_data.json'))),
                                      'init=0',
                                      'output',
                                      paste0('file=',path.expand(file.path(outdir, '03_zip', 'zip_test_data_samples.csv'))),
                                      paste0('refresh=', 1),
                                      'method=sample',
                                      paste0('num_chains=',nchains),
                                      'algorithm=hmc',
                                      #'stepsize=0.00000001',
                                      'engine=nuts',
                                      'max_depth=10',
                                      'adapt t0=10',
                                      'delta=0.8',
                                      'kappa=0.75',
                                      'num_warmup=200',
                                      'num_samples=200',
                                      paste0('num_threads=',nthreads),
                                      (paste0('opencl platform=0 device=', opencl_device))[opencl],
                                      sep=' '),
                          advi = paste('./zip_glm',
                                       paste0('data file=',path.expand(file.path(outdir, '03_zip', 'zip_test_data.json'))),
                                       'output',
                                       paste0('file=',path.expand(file.path(outdir, '03_zip', 'zip_test_data_samples.csv'))),
                                       paste0('refresh=', 100),
                                       'method=variational algorithm=meanfield',
                                       #'grad_samples=1',
                                       #'elbo_samples=1',
                                       'iter=20000',
                                       'eta=0.1',
                                       'adapt engaged=0',
                                       'tol_rel_obj=0.01',
                                       #'eval_elbo=1',
                                       'output_samples=1000',
                                       (paste0('opencl platform=0 device=', opencl_device))[opencl],
                                       sep=' '))

setwd(model_dir)
print(sampling_commands[[algorithm]])
print(date())
system(sampling_commands[[algorithm]])

#stan.fit.var <- cmdstanr::read_cmdstan_csv(Sys.glob(path.expand(file.path(outdir,'03_zip','zip_test_data_samples_*.csv'))),
                                           format = 'draws_array')

#summary(stan.fit.var$post_warmup_sampler_diagnostics)
#plot(apply(stan.fit.var$post_warmup_draws[,1,paste0('L_s[',1:NS,',1]')], 3, mean), apply(stan.fit.var$post_warmup_draws[,1,paste0('L_s[',1:NS,',2]')],3,mean), xlab = "PCA1", ylab = "PCA2",axes = TRUE, main = "First samplewise latent variables", col=as.factor(m2$env.features), pch=16)
