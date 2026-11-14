// LD_PRELOAD sampler: SIGPROF every 100us of CPU time, records the PC; at exit
// writes "pc count" lines to $SAMPLER_OUT. Resolve with symbolize.py.
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <ucontext.h>
#include <stdint.h>
#define N (1<<22)
static uintptr_t pcs[N]; static volatile long n;
static void h(int s, siginfo_t *i, void *c) { (void)s;(void)i; ucontext_t *u=c; long k=n; if(k<N){pcs[k]=u->uc_mcontext.gregs[REG_RIP]; n=k+1;} }
static void done(void) {
  const char *o=getenv("SAMPLER_OUT"); if(!o) return; FILE *f=fopen(o,"w");
  FILE *m=fopen("/proc/self/maps","r"); char line[512]; while(fgets(line,sizeof line,m)) fprintf(f,"#%s",line); fclose(m);
  for(long k=0;k<n;k++) fprintf(f,"%lx\n",pcs[k]); fclose(f);
}
__attribute__((constructor)) static void start(void) {
  if(!getenv("SAMPLER_OUT")) return;
  struct sigaction a={0}; a.sa_sigaction=h; a.sa_flags=SA_SIGINFO|SA_RESTART; sigaction(SIGPROF,&a,0);
  struct itimerval t={{0,100},{0,100}}; setitimer(ITIMER_PROF,&t,0); atexit(done);
}
