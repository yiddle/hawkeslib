import cython
import numpy as np
cimport numpy as cnp

cdef extern from "math.h":
    double exp(double x) nogil
    double log(double x) nogil

cdef extern from "stdlib.h":
    double rand() nogil
    int RAND_MAX

cdef double uu() nogil:
    return <double> rand() / RAND_MAX

cdef extern from "<vector>" namespace "std":
    cdef cppclass vector[T]:
        void push_back(T&) nogil except+
        size_t size()
        T& operator[](size_t)


@cython.boundscheck(False)
@cython.wraparound(False)
def mv_exp_ll(cnp.ndarray[ndim=1, dtype=cnp.float64_t] t,
              cnp.ndarray[ndim=1, dtype=long] c,
              cnp.ndarray[ndim=1, dtype=cnp.float64_t] mu,
              cnp.ndarray[ndim=2, dtype=cnp.float64_t] A, double theta, double T):
    """
    Compute log likelihood for a multivariate Hawkes process with exponential decay

    :param t: the timestamps of a finite realization from a multivariate Hawkes process
    :param c: the 'marks' or the process ids for the realization (note that `len(c) == len(t)` must hold)
    :param mu: the background intensities for the processes, array of length K (number of processes)
    :param A: the infectivity matrix, nonnegative matrix of shape (K, K)
    :param theta: the exponential delay parameter theta
    :param T: the maximum time for which an observation could be made
    """
    cdef:
        int N = t.shape[0]
        int K = np.unique(c).shape[0]
        int i, k
        long ci
        double ti

        cnp.ndarray[ndim=1, dtype=cnp.float64_t] phi = np.zeros(K)
        cnp.ndarray[ndim=1, dtype=cnp.float64_t] d = np.ones(K) * np.inf
        cnp.ndarray[ndim=1, dtype=cnp.float64_t] ed = np.zeros(K)
        cnp.ndarray[ndim=1, dtype=cnp.float64_t] F = np.zeros(K)
        double lJ = 0., lda = 0., dot = 0.

    with nogil:
        # for t0
        F[c[0]] += 1 - exp(-theta * (T - t[0]))
        lJ = log(mu[c[0]])
        d[c[0]] = 0.

        for i in range(1, N):
            ci = c[i]
            ti = t[i]

            dot = 0
            for k in range(K):
                d[k] += ti - t[i-1]
                ed[k] = exp(-theta * d[k])
                phi[k] = ed[k] * (1 + phi[k])
                dot += A[k, ci] * phi[k]

            lda = mu[ci] + theta * dot

            F[ci] += 1 - exp(-theta * (T - ti))

            lJ += log(lda)
            d[ci] = 0.

    return lJ + -np.sum(mu * T) - np.sum(A.T.dot(F))


@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def _get_mv_offspring(double t, cnp.ndarray[ndim=1, dtype=cnp.float64_t] Acp, double theta, double T):
    """
    :param t: time of parent
    :param Acp: A[c_parent, :]
    :param K: int, number of processes
    """
    cdef:
        int Nk, K = Acp.shape[0]
        vector[cnp.float64_t] tos
        vector[long] cos
        int i, j
        long k
        double tt

    for k in range(K):
        Nk = np.random.poisson(Acp[k])
        for j in range(Nk):
            tt = -log(uu()) / theta + t
            tos.push_back(<cnp.float64_t> tt)
            cos.push_back(k)

    cdef cnp.ndarray[cnp.float64_t] tres = np.empty(tos.size(), dtype=np.float)
    cdef cnp.ndarray[long] cres = np.empty(cos.size(), dtype=np.int)
    for i in range(tres.shape[0]):
        tres[i] = tos[i]
        cres[i] = cos[i]

    return tres[tres < T], cres[tres < T]

@cython.boundscheck(False)
@cython.wraparound(False)
def mv_exp_sample_branching(double T,
                            cnp.ndarray[ndim=1, dtype=cnp.float64_t] mu,
                            cnp.ndarray[ndim=2, dtype=cnp.float64_t] A, double theta):
    """
    Implements a branching sampler for a univariate exponential HP, taking advantage of the
    cluster process representation.
    """
    cdef:
        cnp.ndarray[cnp.float64_t] P = np.array([])
        cnp.ndarray[long] C = np.array([], dtype=np.int)

        int Nk_0, K = mu.shape[0]
        int i, k
        cnp.ndarray[cnp.float64_t] curr_P = np.array([])
        cnp.ndarray[long] curr_C = np.array([], dtype=np.int)

    for k in range(K):
        Nk0 = np.random.poisson(mu[k] * T)

        Pk0 = np.random.rand(Nk0) * T
        Ck0 = np.ones(Pk0.shape[0], dtype=np.int) * k

        curr_P = np.concatenate([curr_P, Pk0])
        curr_C = np.concatenate([curr_C, Ck0])

    while curr_P.shape[0] > 0:
        P = np.concatenate([P, curr_P])
        C = np.concatenate([C, curr_C])

        os_P = []  # offspring timestamps
        os_C = []  # offspring marks

        for i in range(len(curr_P)):
            ci = curr_C[i]
            tres, cres = _get_mv_offspring(curr_P[i], A[ci, :], theta, T)
            os_P.append(tres)
            os_C.append(cres)

        curr_P = np.concatenate(os_P)
        curr_C = np.concatenate(os_C)

    six = np.argsort(P, kind="mergesort")

    return P[six], C[six]