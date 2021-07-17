#include functions.stan
data {
    int<lower=2> NT;                        // number of microbial tips
    int<lower=1> NI;                        // number of microbial internal nodes
    vector<lower=0>[NT+NI-1] divergence;    // branch lengths based sequence divergence between adjacent microbial tips/nodes. standardize so mean is 1
    array[NT + NI] int self;                // index for each microbial tip/node in a single vector
    array[NT + NI] int ancestor;            // index for each microbial tip/node's ancestor in a single vector
    int NS;                                 // number of samples
    int NB_s;                               // number of factor levels
    int NSB;                                // number of factors
    array[NB_s] int idx;                    // mapping of sigmas to factor levels
    matrix[NS,NB_s] X_s;                    // model matrix for samples (e.g. tissue compartments, duplicates, sequencing depth, etc.). must include intercept
    array[NT,NS] int count;                 // observations
    real inv_log_max_contam;                // prior expectation of contamination rate
    real<lower=0> shape_gnorm;              // strength of prior pulling contamination toward zero

}
transformed data {
    int NN = NT + NI;
    array[NN] int self_i;
    array[NN] int ancestor_i;
    array[NI] int self_i2;
    for(m in 1:NN){
        self_i[m] = self[m] - NT;
        ancestor_i[m] = ancestor[m] - NT;
        if(self_i[m] > 0) {
            self_i2[self_i[m]] = m;
        }
    }
}
parameters {
    vector<lower=0,upper=1>[NI-1] time_raw;  // fraction of ancestral height for each node
    real<lower=0> seq_div_rate;
    real<lower=0> global_scale_prevalence;
    real<lower=0> global_scale_abundance;
    simplex[2*NSB] var_prop_prevalence;    // proportion of variance of sample effects
    simplex[NSB+1] var_prop_abundance;   // proportion of variance of sample effects
    vector<lower=0>[NSB] sigma_prevalence; // rate of evolution of sample effects
    vector<lower=0>[NSB] sigma_abundance;  //  rate of evolution of sample effects
    vector[NB_s] theta_prevalence; // OU long-term mean or ideal, to which values are attracted. Also interpretable as alpha diversity
    matrix[NB_s,NN] beta_avg;
    matrix[NB_s,NN] beta_diff;
    matrix[NS,NT] abundance_observed;
    vector[NS] multinomial_nuisance;
    real<upper=0> inv_log_less_contamination; // smaller = less average contamination
    real<lower=0> contaminant_overdisp;            // dispersion parameter for amount of contamination in true negative count observations
}
transformed parameters {
    matrix[NB_s,NN] beta_prevalence = beta_avg + beta_diff;
    matrix[NB_s,NN] beta_abundance = beta_avg - beta_diff;
    vector[NN] time_absolute;
    vector[NN] time;
    vector[NN] time_sqrt;
    vector[NN] time_log;
    real log_less_contamination = inv(inv_log_less_contamination);
    vector[2*NSB] sd_prevalence = sqrt(var_prop_prevalence) * global_scale_prevalence;
    vector[NSB+1] sd_abundance = sqrt(var_prop_abundance) * global_scale_abundance;
    vector[NSB] alpha_prevalence_log = 2*(sigma_prevalence - sd_prevalence[1:NSB]) - log2(); // OU alpha_prevalence is function of total variance for each factor and the rate of evolution at each branch (http://web.math.ku.dk/~susanne/StatDiff/Overheads1b)
    vector[NSB] alpha_abundance_log = 2*(sigma_abundance - sd_abundance[1:NSB]) - log2(); // OU alpha_abundance is function of total variance for each factor and the rate of evolution at each branch
    vector[NSB] alpha_prevalence = exp(alpha_prevalence_log);
    vector[NSB] alpha_abundance = exp(alpha_abundance_log);
    time_absolute[self[1]] = 1; //
    time[self[1]] = 1; //
    {
        int i = 1;
        for(m in 2:NN) {
            if(self[m] > NT) {
                // if node is internal, set height as fraction of ancestor's height, and set edge length equal to as difference between the heights
                time_absolute[self[m]] = time_absolute[ancestor[m]] * time_raw[i];
                time[self[m]] = time_absolute[ancestor[m]] - time_absolute[self[m]];
                i += 1;
            } else {
                // if node is a tip, set height as zero, and set edge length equal to height of ancestor
                time_absolute[self[m]] = 0;
                time[self[m]] = time_absolute[ancestor[m]];
            }
        }
    }
    time_sqrt = sqrt(time);
    time_log = log(time);
}
model {
    // data wrangling
    matrix[NS,NN] prevalence = X_s * beta_prevalence;
    matrix[NS,NN] abundance_predicted = X_s * beta_abundance;
    matrix[NS,NN] abundance_contam
      = rep_matrix(beta_abundance[1,]
                   + log_inv_logit(beta_prevalence[1,])
                   + log_less_contamination,
                   NS); // this doesn't allow for phylogenetic correlation in residuals, and doesn't need to be a matrix until it does
    // priors
    target += student_t_lpdf(beta_prevalence[,self[1]] | 5, theta_prevalence, sd_prevalence[idx]);
    target += student_t_lpdf(beta_abundance[,self[1]] | 5, 0, sd_abundance[idx]);
    for(m in 2:NN) {
        vector[NSB] natp = -exp(alpha_prevalence_log + time_log[self[m]]);
        vector[NSB] nata = -exp(alpha_abundance_log + time_log[self[m]]);
        target += student_t_lpdf(beta_prevalence[,self[m]] |
                                 5,
                                 exp(natp)[idx] .* beta_prevalence[,ancestor[m]]
                                 + (1-exp(natp))[idx] .* theta_prevalence,
                                 sigma_prevalence[idx]
                                 .* exp(0.5 * log1m_exp(2 * natp[idx])
                                        - (sigma_prevalence - sd_prevalence[1:NSB])[idx]
                                        - log2()));
        target += student_t_lpdf(beta_abundance[,self[m]] |
                                 5,
                                 exp(nata)[idx] .* beta_abundance[,ancestor[m]],
                                 sigma_abundance[idx]
                                 .* exp(0.5 * log1m_exp(2 * nata[idx])
                                        - (sigma_abundance - sd_abundance[1:NSB])[idx]
                                        - log2()));
    }
    target += student_t_lpdf(seq_div_rate | 5, 0, 2.5);
    target += student_t_lpdf(global_scale_prevalence | 5, 0, 2.5);
    target += student_t_lpdf(global_scale_abundance | 5, 0, 2.5);
    target += student_t_lpdf(sigma_prevalence | 5, 0, 2.5);
    target += student_t_lpdf(sigma_abundance | 5, 0, 2.5);
    target += student_t_lpdf(theta_prevalence | 5, 0, sd_prevalence[(NSB+1):(2*NSB)][idx]);
    target += generalized_std_normal_1_lpdf(inv_log_less_contamination / inv_log_max_contam | shape_gnorm);   // shrink amount of contamination in 'true zeros' toward zero
    target += lognormal_lpdf(contaminant_overdisp | 0, 0.1);                                               // shrink overdispersion of contaminant counts in 'true zeros' toward zero
    // likelihood
    target += student_t_lpdf(divergence | 5, 0, seq_div_rate * append_row(time_sqrt[1:NT],time_sqrt[(NT+2):NN]));
    for(m in 1:NT) {
        for(s in 1:NS) {
            target += log_sum_exp(log1m_inv_logit(prevalence[s,m])
                                  + student_t_lpdf(abundance_observed[s,m] |
                                                   5,
                                                   abundance_contam[s,m],
                                                   contaminant_overdisp * sd_abundance[NSB+1]), //estimated abundance if true negative
                                  log_inv_logit(prevalence[s,m])
                                  + student_t_lpdf(abundance_observed[s,m] |
                                                   5,
                                                   log_sum_exp(abundance_contam[s,m], abundance_predicted[s,m]),
                                                   sd_abundance[NSB+1])); //estimated abundance if true positive
        }
    }
    target += poisson_log_lpmf(to_array_1d(count) |
                               to_vector(abundance_observed + rep_matrix(multinomial_nuisance, NT)));
}
