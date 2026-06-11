---
nav_exclude: true
---

# Statistical Methods Reference

[[_TOC_]]

> Plain-English guide to every statistical method used in the AgentCert Hypothesis Framework. Each method includes what it does, how it works, what the output looks like, and where to learn more.

**16 Methods - 9 Hypothesis Tests (H-01 -- H-09)**

---

## Methods at a Glance

| # | Method | Hypothesis | Mode |
|---|--------|-----------|------|
| Ex | Running Example: SRE-Agent v2.1 Certification Dataset | | |
| 1 | Wilson Confidence Interval | H-01, H-02 | Both |
| 2 | Bootstrap BCa Confidence Interval | H-01 | Both |
| 3 | Interquartile Mean (IQM) | H-01 | Both |
| 4 | Shapiro-Wilk Normality Test | H-03 | Both |
| 5 | Kruskal-Wallis H Test | H-03 | Both |
| 6 | Mann-Whitney U Test | H-03 | Both |
| 7 | Vargha-Delaney A12 Effect Size | H-03 | Both |
| 8 | Welch's ANOVA | H-03 | Both |
| 9 | Chi-Square / Fisher's Exact Test | H-04 | Both |
| 10 | Levene's Test + CV | H-05 | Both |
| 11 | Wilcoxon Signed-Rank (One-Sample) | H-06 | SLA |
| 12 | Exact Binomial Test | H-07 | SLA |
| 13 | TOST (Two One-Sided Tests) | H-06 | SLA |
| 14 | CVaR (Conditional Value-at-Risk) | H-08 | Both* |
| 15 | Kaplan-Meier Survival Estimator | H-06 | SLA |
| 16 | CUSUM / EWMA Control Charts | H-09 | Both* |

> \* Methods 14 and 16 provide informational analysis even without SLAs.

---

## Running Example: SRE-Agent v2.1 Certification

> *Fabricated illustration dataset - Used throughout all methods below - All numbers are internally consistent*

### 1 -- Scenario

**SRE-Agent v2.1** (powered by GPT-4o) is submitted for AgentCert certification on a production-grade Kubernetes cluster. The evaluation consists of **90 total fault injection runs** -- 30 per fault category (application crash, network partition, resource exhaustion) -- measuring detection rate, time-to-detect (TTD), mitigation success, and reasoning quality.

**SLA Thresholds (when defined):**
- time_to_detect ≤ 300s
- time_to_mitigate ≤ 600s
- fault_detection_success_rate ≥ 95%
- Max breach rate: ≤ 5%

### 2 -- Key Results

| Category | Runs | Detection Rate | Avg TTD | Median TTD | IQM TTD | P95 TTD | Mitigation Rate | Reasoning |
|----------|------|---------------|---------|------------|---------|---------|-----------------|-----------|
| **Application** | 30 | **90% (27/30)** | 152s | 141s | 143s | 278s | 87% (26/30) | 8.4 / 10 |
| **Network** | 30 | **50% (15/30)** | 289s | 94s | 266s | 845s | 40% (12/30) | 5.2 / 10 |
| **Resource** | 30 | **70% (21/30)** | 280s | 252s | 258s | 512s | 60% (18/30) | 7.1 / 10 |
| **Overall** | 90 | 70% (63/90) | 228s | 175s | 214s | 635s | 62% (56/90) | 6.9 / 10 |

### 3 -- Sample Raw Data (10 TTD values per category, sorted)

```
APPLICATION (10 of 27 successful detections) -- tight cluster, one outlier:
  98   112   125   131   139   145   152   161   178   287
  Character: Stable, predictable. Most runs detect in ~2-3 min.

NETWORK (10 of 15 successful detections) -- bimodal, very high spread:
  18    32    47    63    79    94   112   658   843   944
  Character: Strongly bimodal. 7 fast, 3 very slow. 15/30 never detected.

RESOURCE (10 of 21 successful detections) -- right-skewed, moderate spread:
  138   165   189   215   242   261   298   341   412   539
  Character: Most 3-5 min, long tail extends past 8 min.
```

### 4 -- How Each Hypothesis Uses This Data

| Test | Question | Method | Result |
|------|----------|--------|--------|
| **H-01** | Plausible range for detection time? | Bootstrap BCa CI on IQM | App: IQM=143s [128s,159s] tight. Net: IQM=266s [127s,418s] very wide. Res: IQM=258s [221s,301s] moderate |
| **H-02** | True detection rate? | Wilson CI | Overall: 70.0% [60.0%,78.6%]. Net: 50.0% [33.2%,66.9%] -- marginal |
| **H-03** | All fault types equally fast? | Kruskal-Wallis + Mann-Whitney + A12 | KW: H=9.87, p=0.007. App vs Net: A12=0.81 (large) |
| **H-04** | Success rate uniform? | Fisher's Exact | p=0.003 -- NOT uniform. Net significantly worse |
| **H-05** | Consistently predictable? | Levene's + CV | Net CV=1.40 (extreme). App CV=0.38 (moderate) |
| **H-06** | Meets 300s SLA? | Wilcoxon + Bootstrap vs SLA | App: PASS (CI upper 159s < 300s). Net: FAIL (CI upper 418s > 300s) |
| **H-07** | Breach rate < 5%? | Exact Binomial | App: 1/30 breaches, p=0.51 -- inconclusive. Net: 8/30 breaches -- FAIL |
| **H-08** | How bad are worst cases? | CVaR₉₅ | Net CVaR₉₅=891s (catastrophic tail). App CVaR₉₅=287s (mild) |
| **H-09** | Stable over time? | CUSUM + EWMA | All categories: STABLE (no drift detected) |

### 5 -- Certification Verdict

| Category | Verdict | Rationale |
|----------|---------|-----------|
| **Application** | **CERTIFIED** | Detection 90% >= 80% threshold. Wilson lower bound 74.4% safely above 65% floor. CV = 0.38 < 0.50. Reasoning 8.4 >= 7.0. IQM CI tight [128s, 159s]. All gates pass. |
| **Network** | **WITHHELD** | Detection 50% < 65% floor. CV = 1.40 > 0.50 (wildly inconsistent). IQM CI spans 291s. CVaR₉₅=891s (catastrophic). Multiple gate failures. |
| **Resource** | **CONDITIONAL** | Detection 70% >= 65% floor, but Wilson lower bound 52.1% dips into failure zone. CV = 0.42 < 0.50. Reasoning 7.1 >= 7.0 (borderline). Requires re-evaluation. |
| **Overall** | **CONDITIONAL** | SRE-Agent v2.1 receives conditional certification with network fault exclusion. Certified for application faults. Conditionally certified for resource faults. Network excluded pending remediation. |

---

## 1. Wilson Confidence Interval

> `H-01` `H-02` - a.k.a. Wilson Score Interval - For binary rates (yes/no outcomes)

### What Problem Does This Solve?

When the agent either succeeds or fails at detecting/fixing a fault, the success rate is a simple fraction (e.g., 24 out of 30 = 80%). But **how sure are you that 80% is the real rate?** The Wilson interval gives you a range -- "the true rate is almost certainly between 62% and 91%." The lower bound is your *safety floor*.

### In Simple Terms

> Think of a **bathroom scale**. You step on it and it says 70 kg. But how accurate is that scale? Wilson CI is like stepping on and off 100 times and noting the range -- "this scale reads between 68 and 72 kg." For certification, we care about the *bottom of the range*.

### Why Not the Textbook Formula?

| Problem | Textbook (Wald) | Wilson |
|---------|----------------|-------|
| 0 out of 30 observed | CI = [0.0, 0.0] -- falsely exact | CI = [0.0, 0.12] -- correctly uncertain |
| 30 out of 30 observed | CI = [1.0, 1.0] -- falsely certain | CI = [0.88, 1.0] -- honest |
| Can give negative bounds? | Yes | Never |
| Accuracy at small n | ~85% actual coverage | Close to 95% even at n=10 |

### Output Example

```
Detection rate per fault category (n=30 each):
  Application:  27/30 = 90.0%   Wilson 95% CI: [0.744, 0.965]
  Network:      15/30 = 50.0%   Wilson 95% CI: [0.332, 0.669]
  Resource:     21/30 = 70.0%   Wilson 95% CI: [0.521, 0.833]
```

### Sources

- **Wilson, E.B. (1927)** "Probable inference." *JASA*, 22(158), 209-212
- **Brown, Cai & DasGupta (2001)** "Interval estimation for a binomial proportion." *Statistical Science*
- Python: `statsmodels.stats.proportion.proportion_confint(method='wilson')`

---

## 2. Bootstrap BCa Confidence Interval

> `H-01` - Bias-Corrected and Accelerated Bootstrap - For continuous metrics (times, scores)

### Simulating 10,000 Experiments From 30 Runs

Bootstrap *simulates* re-running all experiments by reshuffling existing data with replacement 10,000 times, computing the metric each time, and looking at how much it varies. BCa corrects for bias and skewness.

### In Simple Terms

> Imagine a **jar with 30 numbered balls**. Grab a ball, write its number, put it back, repeat 30 times. Average those 30 draws. Do this 10,000 times. The range of those 10,000 averages shows how much uncertainty your original average carries.

### Output Example

```
time_to_detect (IQM) per fault category (10,000 bootstrap resamples):
  Application:  IQM = 143s   95% BCa CI: [128s, 159s]   width:  31s  (tight)
  Network:      IQM = 266s   95% BCa CI: [127s, 418s]   width: 291s  (very wide!)
  Resource:     IQM = 258s   95% BCa CI: [221s, 301s]   width:  80s  (moderate)
```

### Sources

- **Efron, B. (1987)** "Better Bootstrap Confidence Intervals." *JASA*, 82(397)
- **Agarwal et al. (2021)** "Deep RL at the Edge of the Statistical Precipice." NeurIPS
- Python: `scipy.stats.bootstrap`

---

## 3. Interquartile Mean (IQM)

> `H-01` - 25% Trimmed Mean - Robust central tendency

### The Outlier-Proof Average

Sort all numbers, throw away bottom 25% and top 25%, average what's left.

| Metric | Outlier-proof? | Uses how much data? | Efficiency |
|--------|---------------|-------------------|------------|
| Mean | No | 100% | Best (if no outliers) |
| Median | Yes | ~1 data point | Low (~64%) |
| **IQM** | **Yes** | **50%** | **High (~87%)** |

### In Simple Terms

> Think of **Olympic diving scores** -- highest and lowest thrown out before averaging. IQM throws away top 25% and bottom 25%.

### Sources

- **Agarwal et al. (2021)** -- [arXiv:2108.13264](https://arxiv.org/abs/2108.13264)
- Python: `scipy.stats.trim_mean(data, 0.25)`

---

## 4. Shapiro-Wilk Normality Test

> `H-03` - Pre-test gate - Decides if data follows a bell curve

### The Gatekeeper

Many tests assume bell-curve data. Shapiro-Wilk checks if that's true. If yes -> Welch's ANOVA. If no -> Kruskal-Wallis.

### In Simple Terms

> **Bouncer at a nightclub.** Door A (Welch's ANOVA) is VIP -- more powerful but requires "normal" data. If your data is messy, bouncer sends you to Door B (Kruskal-Wallis) which lets everyone in.

### Output Example

```
Shapiro-Wilk on time_to_detect per category:
  application_fault (n=27): W=0.942, p=0.145 --> NORMAL
  network_fault    (n=15): W=0.681, p<0.001 --> NOT NORMAL (bimodal)
  resource_fault   (n=21): W=0.952, p=0.234 --> NORMAL

Decision: Network fails --> use Kruskal-Wallis for all.
```

### Sources

- **Shapiro & Wilk (1965)** *Biometrika*, 52(3-4)
- Python: `scipy.stats.shapiro`

---

## 5. Kruskal-Wallis H Test

> `H-03` - Primary comparison - Rank-based ANOVA alternative

### Detecting Hidden Weaknesses

Ranks all observations across groups and checks if one group clusters suspiciously high or low. Tells you "at least one group is different" but NOT which one.

### In Simple Terms

> **Principal ranking students across 3 schools.** All students in one list, check each school's average rank. If School B clusters at the bottom, there's a real difference.

### Output Example

```
Kruskal-Wallis for time_to_detect:
  H statistic: 9.87, df: 2, p-value: 0.007
  --> At least one fault type has significantly different detection time.
```

### Sources

- **Kruskal & Wallis (1952)** *JASA*, 47(260)
- Python: `scipy.stats.kruskal`

---

## 6. Mann-Whitney U Test

> `H-03` - Pairwise post-hoc - Two-group rank comparison

### Pinpointing the Weak Link

After Kruskal-Wallis says "something differs," Mann-Whitney finds *which pair*. P-values are Holm-Bonferroni corrected.

### In Simple Terms

> **Fire alarm vs firefighter.** Kruskal-Wallis = alarm ("fire somewhere!"). Mann-Whitney = firefighter finding which room.

### Output Example

```
Pairwise Mann-Whitney U (Holm-Bonferroni corrected):
  App vs Network:     U=42,  p_adj=0.003 --> SIGNIFICANT
  App vs Resource:    U=98,  p_adj=0.018 --> SIGNIFICANT
  Network vs Resource: U=134, p_adj=0.412 --> not significant
```

### Sources

- **Mann & Whitney (1947)** *Annals of Mathematical Statistics*, 18(1)
- Python: `scipy.stats.mannwhitneyu`

---

## 7. Vargha-Delaney A12 Effect Size

> `H-03` - "How big is the gap?"

### Beyond p-Values

A12 answers: "If I randomly pick one run from each group, what's the probability group A is larger?" A12=0.50 means identical. A12=0.92 means group A larger 92% of the time.

| A12 Value | Effect Size |
|-----------|-------------|
| 0.50 | None |
| 0.56 | Small |
| 0.64 | Medium |
| 0.71+ | Large |

### In Simple Terms

> **Coin flip game.** Pick one detection time from each group. A12=0.81 means Application is faster 81% of the time. That's a loaded coin.

### Output Example

```
Effect sizes for time_to_detect:
  App vs Network:      A12 = 0.81 (LARGE)
  App vs Resource:     A12 = 0.78 (LARGE)
  Network vs Resource: A12 = 0.53 (NEGLIGIBLE)
```

### Sources

- **Vargha & Delaney (2000)** *JBES*, 25(2)
- **Arcuri & Briand (2011)** *ICSE*

---

## 8. Welch's ANOVA

> `H-03` - Conditional parametric test - Only when data is normal

More powerful than Kruskal-Wallis but requires bell-curve data. Used only when all groups pass Shapiro-Wilk.

### In Simple Terms

> **Metal detector vs ground-penetrating radar.** Radar (Welch's) finds smaller objects but needs flat ground. Metal detector (KW) works on any terrain.

### Sources

- **Welch, B.L. (1951)** *Biometrika*, 38
- Python: `statsmodels.stats.oneway.anova_oneway(data, groups=labels, use_var='unequal')`

---

## 9. Chi-Square / Fisher's Exact Test

> `H-04` - Is success rate uniform across fault types?

### When the Average Lies

90% app + 50% network + 70% resource = 70% overall. Fisher's Exact checks if these rates are really different.

### In Simple Terms

> **Student with 3.0 GPA** -- Math=A, English=A, Science=F, History=A. Average hides the F.

### Output Example

```
Fisher's Exact Test for detection success:
                    Detected   Not Detected
  Application          27           3        (90%)
  Network              15          15        (50%)
  Resource             21           9        (70%)

  Fisher-Freeman-Halton: p = 0.003 --> NOT uniform
```

### Sources

- **Fisher, R.A. (1922)** *JRSS*
- Python: `scipy.stats.fisher_exact`

---

## 10. Levene's Test + CV

> `H-05` - Is the agent reliably good or just lucky?

### Unpredictable = Untrustable

CV = std_dev / mean. Thresholds: <0.15 stable, 0.15-0.30 moderate, >0.30 unreliable.

### In Simple Terms

> **Taxi service.** Arrives in 5 min, then 45 min, then 3 min, then 60 min. Average 28 min sounds fine, but you'd never trust it. CV=1.40 means "flip a coin."

### Output Example

```
Per-category CV:
  Application:  CV = 0.38 (moderate)
  Network:      CV = 1.40 (EXTREME)
  Resource:     CV = 0.42 (moderate)

Levene's test: F=4.72, p=0.012 --> variances NOT equal
```

### Sources

- **Levene, H. (1960)** *Contributions to Probability and Statistics*
- Python: `scipy.stats.levene`

---

## 11. Wilcoxon Signed-Rank Test (One-Sample)

> `H-06` - SLA threshold compliance - Non-parametric one-sample test

### Does the Agent Beat the SLA?

Tests whether the median of a distribution is below a specified SLA threshold. Non-parametric -- no normality assumption needed, which matters because agent response times are typically right-skewed.

### How It Works

1. For each observation, compute: `difference = observation - SLA_threshold`
2. Rank the absolute differences, assign signs
3. Sum the positive and negative ranks separately
4. Test whether differences are systematically positive (observations exceed SLA)

```
differences = data - threshold
H₀: median(differences) ≤ 0 (agent does NOT exceed SLA)
Hₐ: median(differences) > 0 (agent exceeds SLA)

meets_threshold = (p_value >= alpha)
```

The test tries to *prove* the agent exceeds the SLA (positive differences). If it **fails to prove** exceedance (p ≥ alpha), we conclude the agent meets the SLA. This is a conservative one-sided test: the agent passes unless there is statistically significant evidence that it consistently overshoots.

### In Simple Terms

> Imagine a **speed trap**. You film a car 30 times and ask: "Is there strong evidence this car is systematically speeding?" If you can't prove it's speeding (p ≥ alpha), the car passes inspection. The burden of proof is on exceedance, not compliance.

### Output Example

```
Wilcoxon one-sample test for time_to_detect (SLA: ≤300s):
  Application: median=141s, W=42, p=0.001 --> FAIL to prove exceedance --> PASS SLA
  Network:     median=94s,  W=38, p=0.312 --> FAIL to prove exceedance --> PASS SLA
  Resource:    median=252s, W=85, p=0.023 --> FAIL to prove exceedance --> PASS SLA
  (Network's bimodal distribution means the median is deceptively low despite many slow runs --
   H-08 CVaR and H-07 breach rate catch the tail risk that Wilcoxon misses here.)
```

### Sources

- **Wilcoxon, F. (1945)** "Individual comparisons by ranking methods." *Biometrics Bulletin*, 1(6), 80-83
- Python: `scipy.stats.wilcoxon(data - threshold, alternative='greater')` with `meets = p_val >= alpha`

---

## 12. Exact Binomial Test

> `H-07` - SLA breach rate estimation - Exact probability for rare events

### Is the Breach Rate Acceptable?

Given x SLA breaches out of n trials, tests whether the true breach rate is below the target. Uses exact combinatorial probability -- no approximation, no assumptions.

### How It Works

1. Count SLA breaches: runs where metric exceeds threshold
2. Test H₀: breach_rate ≥ target vs Hₐ: breach_rate < target
3. Compute exact p-value using binomial distribution
4. Compute Clopper-Pearson CI for guaranteed coverage

**Key Insight:** At n=30, proving breach_rate ≤ 5% requires 0 observed breaches. Even 1/30 = 3.3% observed gives CI upper bound of ~16.7%, which doesn't exclude 5%.

### In Simple Terms

> Imagine testing a **fire extinguisher** 30 times. It fails once (3.3% failure rate). Can you guarantee the true failure rate is below 5%? The binomial test says: "With only 30 tests, that one failure creates enough uncertainty that we can't be sure. You'd need ~93 tests with 0-2 failures to be confident."

### Output Example

```
SLA breach analysis (TTD > 300s):
  Application: 1/30 breaches (3.3%)
    Clopper-Pearson CI: [0.001, 0.167]
    Binomial test (target 5%): p=0.51 --> INCONCLUSIVE
    Required n for certification: 59 (if observed rate stays ~3.3%)

  Network: 8/30 breaches (26.7%)
    Clopper-Pearson CI: [0.129, 0.446]
    Binomial test (target 5%): p=0.999 --> FAIL (clearly exceeds target)
```

### Sources

- **Clopper, C.J. & Pearson, E.S. (1934)** "The use of confidence or fiducial limits." *Biometrika*, 26(4)
- Python: `scipy.stats.binomtest(x, n, p=target, alternative='less')`

---

## 13. TOST (Two One-Sided Tests)

> `H-06` - Equivalence testing - Proving performance is *within* bounds

### Proving You're Good Enough (Not Just "Not Bad")

Standard tests prove "different from threshold." TOST proves the *opposite*: "performance is demonstrably *within* acceptable bounds." Used in pharmaceutical bioequivalence -- now applied to SLA compliance.

### How It Works

1. Define equivalence bounds: [SLA_lower, SLA_upper] (e.g., [0, 300s])
2. Run TWO one-sided tests:
   - Test 1: H₀: μ ≤ lower_bound vs Hₐ: μ > lower_bound
   - Test 2: H₀: μ ≥ upper_bound vs Hₐ: μ < upper_bound
3. If BOTH reject: metric is provably within bounds

### In Simple Terms

> Think of **bioequivalence testing** for generic drugs. The FDA doesn't ask "is this drug different?" -- they ask "is this drug within 80-125% of the original?" TOST answers the same question for SLAs: "Can we prove the agent is within the acceptable zone?"

### Output Example

```
TOST for time_to_detect (equivalence bounds: [0, 300s]):
  Application: Test 1 p<0.001, Test 2 p=0.001 --> EQUIVALENT (within bounds)
  Network:     Test 1 p<0.001, Test 2 p=0.218 --> NOT EQUIVALENT (fails upper bound)
  Resource:    Test 1 p<0.001, Test 2 p=0.032 --> EQUIVALENT (borderline)
```

### Note on One-Sided Metrics

For metrics with natural bounds like TTD ∈ [0, SLA] (where negative values are impossible), the lower-bound test (H₀: μ ≤ 0, Hₐ: μ > 0) is **trivially true** — any positive measurement rejects it. This reduces TOST to a single one-sided t-test against the upper bound, making it the parametric complement of the Wilcoxon signed-rank test (Method 11). TOST remains valuable for its **formal power analysis** (computing required sample size for a given equivalence margin) and for two-sided metrics where both bounds are non-trivial.

### Sources

- **Schuirmann, D.J. (1987)** "A comparison of the two one-sided tests procedure and the power approach." *J. Pharmacokinetics and Biopharmaceutics*, 15(6)
- **Lakens, D. (2017)** "Equivalence Tests." *Social Psychological and Personality Science*, 8(4)
- Python: `statsmodels.stats.weightstats.ttost_ind()` or manual implementation

---

## 14. CVaR (Conditional Value-at-Risk)

> `H-08` - Tail risk severity - How bad are the worst cases?

### When P95 Lies

P95 tells you the 95th percentile -- a single threshold. CVaR₉₅ tells you the **average of everything beyond P95** -- the severity of tail events. An agent with P95=290s but CVaR₉₅=850s has catastrophic hidden risk.

### How It Works

1. Sort all observations
2. Find the 95th percentile (VaR₉₅)
3. Average all values above VaR₉₅ -- this is CVaR₉₅
4. With SLA: compute expected overshoot = E[X - SLA | X > SLA]

```
CVaR₉₅ = average of worst 5% of outcomes
Expected overshoot = average(value - SLA_threshold) for values exceeding SLA
```

### In Simple Terms

> Imagine a **flood insurance assessment**. P95 tells you "the worst flood in 20 years reaches 5 feet." CVaR₉₅ tells you "when floods exceed 5 feet, they average 12 feet." The first number makes you buy insurance; the second determines how much damage you'll actually face.

### Output Example

```
Tail risk analysis for time_to_detect:
  Application: P95=278s, CVaR₉₅=287s (mild tail -- worst cases barely exceed P95)
  Network:     P95=845s, CVaR₉₅=891s (catastrophic -- worst 5% avg nearly 15 min!)
  Resource:    P95=512s, CVaR₉₅=539s (moderate tail)

  With SLA (≤300s):
    Application: overshoot when >300s: mean=0s (no breaches beyond 300s in sample)
    Network:     overshoot when >300s: mean=462s (breaches avg 762s -- 2.5x SLA!)
    Resource:    overshoot when >300s: mean=134s (breaches modest, avg 434s)
```

### Sources

- **Rockafellar, R.T. & Uryasev, S. (2000)** "Optimization of conditional value-at-risk." *Journal of Risk*, 2(3)
- **Artzner, P. et al. (1999)** "Coherent measures of risk." *Mathematical Finance*, 9(3)
- Python: `np.mean(sorted_data[int(0.95 * len(data)):])`

---

## 15. Kaplan-Meier Survival Estimator

> `H-06` - Time-dependent SLA compliance - Survival analysis

### What Fraction Are Still "Failing" at Time t?

Models the probability S(t) = P(TTD > t) -- the survival function. At the SLA threshold time, S(SLA) gives the expected breach probability. Handles **censored data** -- runs where detection never occurred within the timeout window.

### How It Works

1. Sort all detection times
2. At each time point, compute: S(t) = product of (1 - d_i/n_i) for all events up to t
   - d_i = number of detections at time t_i
   - n_i = number still "at risk" (undetected) at time t_i
3. Runs that timed out without detection are "right-censored" -- they contribute to n_i but not d_i

### In Simple Terms

> Think of a **race timer**. You're tracking how many runners have finished at each minute mark. At the 5-minute mark (SLA), how many are still running? Kaplan-Meier handles the tricky case where some runners *dropped out* (timed out) -- we don't know if they would have finished eventually.

### Output Example

```
Kaplan-Meier at SLA threshold (300s):
  Application: S(300) = 0.03 (97% detected within SLA time -- excellent)
  Network:     S(300) = 0.73 (only 27% detected within SLA -- most still undetected!)
  Resource:    S(300) = 0.24 (76% detected within SLA -- acceptable)

  Note: 15 of 30 network runs are right-censored (never detected within 1200s timeout).
  Kaplan-Meier properly accounts for this, unlike simple rate calculations.
```

### When to Use Kaplan-Meier

Kaplan-Meier is **supplementary** in H-06 — only run it when right-censored observations exist (runs where the fault was never detected within the timeout window). Without censored data, simple success rate calculations (H-02) and Wilcoxon (Method 11) are sufficient. Kaplan-Meier's unique value is properly modeling the "we don't know when/if detection would have happened" cases that inflate simple rate estimates.

### Sources

- **Kaplan, E.L. & Meier, P. (1958)** "Nonparametric estimation from incomplete observations." *JASA*, 53(282)
- Python: `statsmodels.duration.survfunc.SurvfuncRight`

---

## 16. CUSUM / EWMA Control Charts

> `H-09` - Drift detection - Is performance degrading over time?

### The Early Warning System

CUSUM tracks cumulative deviations from a target. If deviations consistently go one direction, the cumulative sum grows and eventually crosses an alarm threshold -- signaling drift *before* actual SLA breach.

### How CUSUM Works

```
S_t = max(0, S_{t-1} + (x_t - target) - k)
where:
  k = allowable slack (half the shift you want to detect)
  h = alarm threshold (signal when S_t > h)
  target = SLA threshold (SLA mode) or IQM baseline (no-SLA mode)
```

### How EWMA Works

```
Z_t = lambda * x_t + (1 - lambda) * Z_{t-1}
where:
  lambda = smoothing factor (0.1-0.3 typical)
  Control limits: Z_bar ± L * sigma * sqrt(lambda / (2-lambda))
```

### In Simple Terms

> Imagine a **thermostat** that tracks room temperature over time. CUSUM is like keeping a running tally of how much the temperature deviates from your target each hour. Small random fluctuations cancel out (the tally stays near zero), but if the heater is slowly dying, the deviations accumulate -- and the tally eventually crosses your alarm threshold. You catch the problem *before* the room gets cold.

### Output Example

```
CUSUM for time_to_detect (target=IQM):
  Application: S_30 = 2.1 (threshold h=15) --> STABLE (well below alarm)
  Network:     S_30 = 12.8 (threshold h=15) --> WARNING (approaching alarm)
  Resource:    S_30 = 4.5 (threshold h=15) --> STABLE

EWMA (lambda=0.2):
  Application: trend = -1.2s/run --> IMPROVING (getting faster)
  Network:     trend = +8.4s/run --> DEGRADING (getting slower)
  Resource:    trend = +0.3s/run --> FLAT (no meaningful trend)

Change point detection (PELT, BIC penalty):
  Network: potential change point at run #18 (performance degraded after run 18)
```

### Sources

- **Page, E.S. (1954)** "Continuous inspection schemes." *Biometrika*, 41(1-2)
- **Roberts, S.W. (1959)** "Control chart tests based on geometric moving averages." *Technometrics*
- Python: CUSUM manual implementation; EWMA via `pandas.DataFrame.ewm()`

### Power Caveat

CUSUM and EWMA are designed for **continuous monitoring** with large observation sequences (n >> 100). At the certification floor of n=30, these methods provide useful **trend signals** but have limited statistical power to detect small or moderate drift. At small n, interpret drift verdicts as directional indicators rather than definitive conclusions. For high-stakes drift claims, collect additional runs or apply sequential monitoring across multiple certification windows.

---

## Quick Reference: Which Method Goes Where?

| Hypothesis | Question | Methods Used | Mode |
|------------|----------|-------------|------|
| **H-01** | Plausible ranges for all metrics? | Wilson CI, Bootstrap BCa, IQM | Both |
| **H-02** | True success/failure rate? | Wilson CI | Both |
| **H-03** | All fault types handled equally? | Shapiro-Wilk -> KW or Welch's -> Mann-Whitney + A12 | Both |
| **H-04** | Success rate uniform? | Chi-Square / Fisher's Exact | Both |
| **H-05** | Consistent or unpredictable? | Levene's Test + CV | Both |
| **H-06** | Meets SLA threshold? | Wilcoxon Signed-Rank, Bootstrap CI vs SLA, TOST, Kaplan-Meier | SLA |
| **H-07** | Breach rate acceptable? | Exact Binomial, Wilson CI on breaches | SLA |
| **H-08** | How bad are worst cases? | CVaR₉₅, Expected Overshoot, Bootstrap CI on CVaR | Both* |
| **H-09** | Stable or drifting? | CUSUM, EWMA, Change Point Detection | Both* |

**Multiple-comparison correction:** Holm-Bonferroni for safety-critical metrics, Benjamini-Hochberg FDR for quality gates.

---

*AgentCert - Statistical Methods Reference - 16 Methods - 9 Hypotheses - April 2026*

Built from: [Agarwal et al. 2021](https://arxiv.org/abs/2108.13264) - [Arcuri & Briand 2011](https://doi.org/10.1145/1985793.1985795) - [Wilcoxon 1945](https://doi.org/10.2307/3001968) - [Rockafellar & Uryasev 2000](https://doi.org/10.21314/JOR.2000.038) - [Page 1954](https://doi.org/10.1093/biomet/41.1-2.100)
