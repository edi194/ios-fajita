// prints sysctl kern.sweet_gpu (the Adreno driver's metrics line)
#include <stdio.h>
#include <sys/sysctl.h>
int main(void)
{
   char buf[2048];
   size_t n = sizeof(buf);
   if (sysctlbyname("kern.sweet_gpu", buf, &n, NULL, 0) != 0) { perror("kern.sweet_gpu"); return 1; }
   printf("%.*s\n", (int)n, buf);
   return 0;
}
