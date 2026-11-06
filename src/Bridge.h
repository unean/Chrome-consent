#pragma once
#include <stdint.h>
int cc_lock_state(void);
int cc_console_uid(void);
int cc_install_ready(void);
int cc_parent_is_app(int pid);
int cc_socket_listen(void);
int cc_socket_connect(void);
int cc_peer_is_app(int fd);
int cc_peer_is_security_agent(int fd);
void cc_socket_cleanup(void);
int cc_read_line(int fd, char *buffer, int size);
int cc_write_line(int fd, const char *text);
int cc_lock_available(void);
void cc_request_lock(void);
int cc_login_pid(void);
int cc_submit_login(int expected_pid);
