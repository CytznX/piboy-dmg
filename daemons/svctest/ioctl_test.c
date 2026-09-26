#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <signal.h>
#include <linux/input.h>
int main(void){ char n[256]; int fd=0; return ioctl(fd, EVIOCGNAME(sizeof(n)), n); }
