/* Non-shell stand-in for the Kiro CLI terminal wrapper. Like the real
 * `zsh (kiro-cli-term)`, it holds the tmux pane's tty in raw mode and runs its
 * command on a separate pty, relaying bytes both ways. */
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

int main(int argc, char **argv) {
  struct termios raw;
  char buf[4096];
  ssize_t n;
  int master;
  pid_t pid;

  if (argc < 2) return 2;
  pid = forkpty(&master, NULL, NULL, NULL);
  if (pid < 0) return 1;
  if (pid == 0) {
    execv(argv[1], argv + 1);
    _exit(127);
  }
  if (tcgetattr(0, &raw) == 0) {
    cfmakeraw(&raw);
    tcsetattr(0, TCSANOW, &raw);
  }
  for (;;) {
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(0, &fds);
    FD_SET(master, &fds);
    if (select(master + 1, &fds, NULL, NULL, NULL) < 0) continue;
    if (FD_ISSET(0, &fds)) {
      n = read(0, buf, sizeof buf);
      if (n <= 0) break;
      if (write(master, buf, (size_t)n) < 0) break;
    }
    if (FD_ISSET(master, &fds)) {
      n = read(master, buf, sizeof buf);
      if (n <= 0) break;
      if (write(1, buf, (size_t)n) < 0) break;
    }
  }
  return 0;
}
