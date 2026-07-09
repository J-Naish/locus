//! Minimal POSIX PTY process management for the terminal integration.
//!
//! The crate intentionally owns no read thread. Callers watch [`Pty::master_fd`]
//! with their platform event loop and drive [`Pty::read`] when the descriptor is
//! readable.

use std::env;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fmt;
use std::io;
use std::os::fd::RawFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
#[link(name = "util")]
extern "C" {}

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;
const FALLBACK_LOGIN_SHELL: &str = "/bin/zsh";
const DEFAULT_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
const SHUTDOWN_GRACE: Duration = Duration::from_millis(200);
const SHUTDOWN_POLL: Duration = Duration::from_millis(10);
const DROP_REAP_GRACE: Duration = Duration::from_millis(5);

/// Options used to spawn a child process attached to a new pseudo-terminal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PtyOptions {
    pub cols: u16,
    pub rows: u16,
    pub command: Option<PathBuf>,
    pub args: Vec<OsString>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(OsString, OsString)>,
}

impl Default for PtyOptions {
    fn default() -> Self {
        Self {
            cols: DEFAULT_COLS,
            rows: DEFAULT_ROWS,
            command: None,
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
        }
    }
}

/// Exit status reported for a finished PTY child.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExitStatus {
    pub code: Option<i32>,
    pub signal: Option<i32>,
}

impl ExitStatus {
    fn from_wait_status(status: libc::c_int) -> Self {
        if libc::WIFEXITED(status) {
            Self {
                code: Some(libc::WEXITSTATUS(status)),
                signal: None,
            }
        } else if libc::WIFSIGNALED(status) {
            Self {
                code: None,
                signal: Some(libc::WTERMSIG(status)),
            }
        } else {
            Self {
                code: None,
                signal: None,
            }
        }
    }

    pub fn success(self) -> bool {
        self.code == Some(0) && self.signal.is_none()
    }
}

/// Errors surfaced by the safe PTY API.
#[derive(Debug)]
pub enum PtyError {
    InvalidDimensions,
    InvalidCwd(PathBuf),
    InvalidEnvKey(OsString),
    NulByte,
    BadCommand(PathBuf),
    ChildExecFailed(i32),
    WouldBlock,
    Timeout,
    Io(io::Error),
}

impl PtyError {
    pub fn errno(&self) -> Option<i32> {
        match self {
            Self::ChildExecFailed(errno) => Some(*errno),
            Self::Io(error) => error.raw_os_error(),
            _ => None,
        }
    }
}

impl fmt::Display for PtyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidDimensions => formatter.write_str("PTY dimensions must be non-zero"),
            Self::InvalidCwd(path) => {
                write!(formatter, "PTY cwd is not a directory: {}", path.display())
            }
            Self::InvalidEnvKey(key) => {
                write!(formatter, "PTY environment key is invalid: {:?}", key)
            }
            Self::NulByte => formatter.write_str("PTY string contains an embedded NUL byte"),
            Self::BadCommand(path) => write!(
                formatter,
                "PTY command is not executable: {}",
                path.display()
            ),
            Self::ChildExecFailed(errno) => {
                let error = io::Error::from_raw_os_error(*errno);
                write!(formatter, "PTY child setup or exec failed: {error}")
            }
            Self::WouldBlock => formatter.write_str("PTY descriptor is not ready"),
            Self::Timeout => formatter.write_str("PTY shutdown timed out"),
            Self::Io(error) => write!(formatter, "PTY I/O failed: {error}"),
        }
    }
}

impl std::error::Error for PtyError {}

impl From<io::Error> for PtyError {
    fn from(value: io::Error) -> Self {
        if value.kind() == io::ErrorKind::WouldBlock {
            Self::WouldBlock
        } else {
            Self::Io(value)
        }
    }
}

type Result<T> = std::result::Result<T, PtyError>;

/// Running child process attached to a pseudo-terminal.
#[derive(Debug)]
pub struct Pty {
    master_fd: RawFd,
    child_pid: libc::pid_t,
    exited: Option<ExitStatus>,
}

impl Pty {
    /// Spawn a child process attached to a newly allocated PTY.
    pub fn spawn(options: PtyOptions) -> Result<Self> {
        if options.cols == 0 || options.rows == 0 {
            return Err(PtyError::InvalidDimensions);
        }
        if let Some(cwd) = options.cwd.as_ref() {
            if !cwd.is_dir() {
                return Err(PtyError::InvalidCwd(cwd.clone()));
            }
        }

        let launch = LaunchPlan::new(&options)?;
        let mut winsize = libc::winsize {
            ws_row: options.rows,
            ws_col: options.cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        let mut master_fd: RawFd = -1;
        let mut slave_fd: RawFd = -1;
        // SAFETY: openpty initializes the two output fd pointers on success.
        // name/termios are null because the caller does not need a PTY name and
        // wants default terminal attributes. winsize points to a valid value.
        let open_result = unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut winsize,
            )
        };
        if open_result == -1 {
            return Err(PtyError::Io(io::Error::last_os_error()));
        }

        if let Err(error) = set_cloexec(master_fd).and_then(|()| set_nonblocking(master_fd)) {
            close_fd(master_fd);
            close_fd(slave_fd);
            return Err(error);
        }

        let mut error_pipe = [-1; 2];
        // SAFETY: pipe writes two fds into the provided array on success.
        if unsafe { libc::pipe(error_pipe.as_mut_ptr()) } == -1 {
            close_fd(master_fd);
            close_fd(slave_fd);
            return Err(PtyError::Io(io::Error::last_os_error()));
        }
        if let Err(error) = set_cloexec(error_pipe[0]).and_then(|()| set_cloexec(error_pipe[1])) {
            close_fd(error_pipe[0]);
            close_fd(error_pipe[1]);
            close_fd(master_fd);
            close_fd(slave_fd);
            return Err(error);
        }

        let argv_ptrs = launch.argv_ptrs();
        let envp_ptrs = launch.envp_ptrs();

        // SAFETY: fork duplicates the current process. The child immediately
        // performs only descriptor/session setup and execs or exits.
        let pid = unsafe { libc::fork() };
        if pid == -1 {
            close_fd(error_pipe[0]);
            close_fd(error_pipe[1]);
            close_fd(master_fd);
            close_fd(slave_fd);
            return Err(PtyError::Io(io::Error::last_os_error()));
        }

        if pid == 0 {
            run_child(
                slave_fd,
                master_fd,
                error_pipe[0],
                error_pipe[1],
                &launch,
                &argv_ptrs,
                &envp_ptrs,
            );
        }

        close_fd(slave_fd);
        close_fd(error_pipe[1]);

        let exec_result = read_child_exec_result(error_pipe[0]);
        close_fd(error_pipe[0]);
        if let Err(error) = exec_result {
            close_fd(master_fd);
            reap_child_nonblocking(pid, DROP_REAP_GRACE);
            return Err(error);
        }

        Ok(Self {
            master_fd,
            child_pid: pid,
            exited: None,
        })
    }

    /// Master PTY file descriptor. It is owned by this [`Pty`] and remains
    /// valid until `shutdown`, `drop`, or an explicit free through FFI.
    pub fn master_fd(&self) -> RawFd {
        self.master_fd
    }

    pub fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        if self.master_fd < 0 {
            return Ok(0);
        }
        if buf.is_empty() {
            return Ok(0);
        }
        loop {
            // SAFETY: master_fd is an open descriptor owned by self. buf is a
            // valid writable byte slice for the provided length.
            let read_count = unsafe {
                libc::read(
                    self.master_fd,
                    buf.as_mut_ptr().cast::<libc::c_void>(),
                    buf.len(),
                )
            };
            if read_count >= 0 {
                return Ok(read_count as usize);
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            if is_would_block(&error) {
                return Err(PtyError::WouldBlock);
            }
            return Err(PtyError::Io(error));
        }
    }

    pub fn write(&mut self, bytes: &[u8]) -> Result<usize> {
        if self.master_fd < 0 || bytes.is_empty() {
            return Ok(0);
        }
        loop {
            // SAFETY: master_fd is an open descriptor owned by self. bytes is a
            // valid readable byte slice for the provided length.
            let written = unsafe {
                libc::write(
                    self.master_fd,
                    bytes.as_ptr().cast::<libc::c_void>(),
                    bytes.len(),
                )
            };
            if written >= 0 {
                return Ok(written as usize);
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            if is_would_block(&error) {
                return Err(PtyError::WouldBlock);
            }
            return Err(PtyError::Io(error));
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        if cols == 0 || rows == 0 {
            return Err(PtyError::InvalidDimensions);
        }
        if self.master_fd < 0 {
            return Ok(());
        }
        let winsize = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: master_fd is an open PTY master. TIOCSWINSZ reads the
        // winsize struct synchronously and does not retain the pointer.
        if unsafe { libc::ioctl(self.master_fd, libc::TIOCSWINSZ, &winsize) } == -1 {
            return Err(PtyError::Io(io::Error::last_os_error()));
        }
        Ok(())
    }

    pub fn window_size(&self) -> Result<(u16, u16)> {
        if self.master_fd < 0 {
            return Err(PtyError::Io(io::Error::from_raw_os_error(libc::EBADF)));
        }
        let mut winsize = libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: master_fd is an open PTY master. TIOCGWINSZ writes into the
        // stack-allocated winsize value during the call.
        if unsafe { libc::ioctl(self.master_fd, libc::TIOCGWINSZ, &mut winsize) } == -1 {
            return Err(PtyError::Io(io::Error::last_os_error()));
        }
        Ok((winsize.ws_col, winsize.ws_row))
    }

    pub fn try_wait(&mut self) -> Result<Option<ExitStatus>> {
        if let Some(status) = self.exited {
            return Ok(Some(status));
        }
        let mut status = 0;
        loop {
            // SAFETY: child_pid is the pid returned by fork for this Pty.
            let result = unsafe { libc::waitpid(self.child_pid, &mut status, libc::WNOHANG) };
            if result == 0 {
                return Ok(None);
            }
            if result == self.child_pid {
                let status = ExitStatus::from_wait_status(status);
                self.exited = Some(status);
                return Ok(Some(status));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::ECHILD) => return Ok(self.exited),
                _ => return Err(PtyError::Io(error)),
            }
        }
    }

    /// Gracefully terminate the child, escalating to SIGKILL after a bounded
    /// grace window. Calling shutdown repeatedly is allowed.
    pub fn shutdown(&mut self) -> Result<Option<ExitStatus>> {
        self.close_master();
        if self.exited.is_some() {
            return Ok(self.exited);
        }
        send_signal(self.child_pid, libc::SIGHUP);
        let deadline = Instant::now() + SHUTDOWN_GRACE;
        while Instant::now() < deadline {
            if let Some(status) = self.try_wait()? {
                return Ok(Some(status));
            }
            thread::sleep(SHUTDOWN_POLL);
        }
        send_signal(self.child_pid, libc::SIGKILL);
        self.wait_blocking()
    }

    fn wait_blocking(&mut self) -> Result<Option<ExitStatus>> {
        if let Some(status) = self.exited {
            return Ok(Some(status));
        }
        let mut status = 0;
        loop {
            // SAFETY: child_pid is the pid returned by fork for this Pty.
            let result = unsafe { libc::waitpid(self.child_pid, &mut status, 0) };
            if result == self.child_pid {
                let status = ExitStatus::from_wait_status(status);
                self.exited = Some(status);
                return Ok(Some(status));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::ECHILD) => return Ok(self.exited),
                _ => return Err(PtyError::Io(error)),
            }
        }
    }

    fn close_master(&mut self) {
        if self.master_fd >= 0 {
            close_fd(self.master_fd);
            self.master_fd = -1;
        }
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        self.close_master();
        if self.exited.is_none() {
            send_signal(self.child_pid, libc::SIGHUP);
            self.exited = reap_child_nonblocking(self.child_pid, DROP_REAP_GRACE);
        }
    }
}

struct LaunchPlan {
    program: CString,
    argv: Vec<CString>,
    envp: Vec<CString>,
    cwd: Option<CString>,
}

impl LaunchPlan {
    fn new(options: &PtyOptions) -> Result<Self> {
        let env = build_child_env(&options.env)?;
        let program_path = match options.command.as_ref() {
            Some(command) => resolve_command(command, &env)?,
            None => login_shell_path(),
        };
        let program = cstring_from_os_str(program_path.as_os_str())?;

        let mut argv = Vec::with_capacity(options.args.len() + 1);
        argv.push(program.clone());
        for arg in &options.args {
            argv.push(cstring_from_os_str(arg)?);
        }

        let envp = env_pairs_to_cstrings(&env)?;
        let cwd = options
            .cwd
            .as_ref()
            .map(|path| cstring_from_os_str(path.as_os_str()))
            .transpose()?;

        Ok(Self {
            program,
            argv,
            envp,
            cwd,
        })
    }

    fn argv_ptrs(&self) -> Vec<*const libc::c_char> {
        let mut ptrs: Vec<_> = self.argv.iter().map(|value| value.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        ptrs
    }

    fn envp_ptrs(&self) -> Vec<*const libc::c_char> {
        let mut ptrs: Vec<_> = self.envp.iter().map(|value| value.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        ptrs
    }
}

fn run_child(
    slave_fd: RawFd,
    master_fd: RawFd,
    error_read: RawFd,
    error_write: RawFd,
    launch: &LaunchPlan,
    argv: &[*const libc::c_char],
    envp: &[*const libc::c_char],
) -> ! {
    // Between fork and execve the child must stay async-signal-safe: no heap
    // allocation and no lock acquisition. argv/envp pointer arrays are built
    // by the parent before fork and remain valid in the child's copied address
    // space until execve.
    close_fd(master_fd);
    close_fd(error_read);

    if child_setup(slave_fd, launch).is_err() {
        write_errno_and_exit(error_write);
    }

    // SAFETY: program points to a NUL-terminated CString in launch. argv/envp
    // were built before fork from CStrings owned by launch, are null-terminated,
    // and all referenced storage remains alive until execve succeeds or returns.
    unsafe {
        libc::execve(launch.program.as_ptr(), argv.as_ptr(), envp.as_ptr());
    }
    write_errno_and_exit(error_write);
}

fn child_setup(slave_fd: RawFd, launch: &LaunchPlan) -> Result<()> {
    // SAFETY: setsid affects only this freshly forked child process.
    if unsafe { libc::setsid() } == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    // SAFETY: slave_fd is the open PTY slave for this child. TIOCSCTTY does
    // not retain the argument pointer; the zero pointer argument is the POSIX
    // "do not steal" flag value.
    if unsafe { libc::ioctl(slave_fd, libc::TIOCSCTTY as libc::c_ulong, 0) } == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    if let Some(cwd) = launch.cwd.as_ref() {
        // SAFETY: cwd is a NUL-terminated path CString.
        if unsafe { libc::chdir(cwd.as_ptr()) } == -1 {
            return Err(PtyError::Io(io::Error::last_os_error()));
        }
    }
    duplicate_fd(slave_fd, libc::STDIN_FILENO)?;
    duplicate_fd(slave_fd, libc::STDOUT_FILENO)?;
    duplicate_fd(slave_fd, libc::STDERR_FILENO)?;
    if slave_fd > libc::STDERR_FILENO {
        close_fd(slave_fd);
    }
    Ok(())
}

fn duplicate_fd(source: RawFd, target: RawFd) -> Result<()> {
    if source == target {
        return Ok(());
    }
    // SAFETY: source is an open fd in the child; target is one of stdio fds.
    if unsafe { libc::dup2(source, target) } == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    Ok(())
}

fn write_errno_and_exit(error_write: RawFd) -> ! {
    let errno = io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO);
    let bytes = errno.to_ne_bytes();
    // SAFETY: error_write is a pipe fd inherited by this child. The byte slice
    // is valid for the duration of this synchronous write.
    unsafe {
        let _ = libc::write(
            error_write,
            bytes.as_ptr().cast::<libc::c_void>(),
            bytes.len(),
        );
        libc::_exit(127);
    }
}

fn read_child_exec_result(error_read: RawFd) -> Result<()> {
    let mut bytes = [0_u8; std::mem::size_of::<i32>()];
    let mut filled = 0;
    while filled < bytes.len() {
        // SAFETY: error_read is the read end of a pipe. bytes[filled..] is a
        // valid writable region for the requested length.
        let count = unsafe {
            libc::read(
                error_read,
                bytes[filled..].as_mut_ptr().cast::<libc::c_void>(),
                bytes.len() - filled,
            )
        };
        if count == 0 {
            return if filled == 0 {
                Ok(())
            } else {
                Err(PtyError::ChildExecFailed(libc::EIO))
            };
        }
        if count > 0 {
            filled += count as usize;
            continue;
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        return Err(PtyError::Io(error));
    }
    Err(PtyError::ChildExecFailed(i32::from_ne_bytes(bytes)))
}

fn build_child_env(overrides: &[(OsString, OsString)]) -> Result<Vec<(OsString, OsString)>> {
    let mut env_pairs = Vec::new();
    for (key, value) in env::vars_os() {
        if should_inherit_env(&key) {
            set_env_pair(&mut env_pairs, key, value)?;
        }
    }
    set_env_pair(
        &mut env_pairs,
        OsString::from("TERM"),
        OsString::from("xterm-256color"),
    )?;
    set_env_pair(
        &mut env_pairs,
        OsString::from("COLORTERM"),
        OsString::from("truecolor"),
    )?;
    for (key, value) in overrides {
        set_env_pair(&mut env_pairs, key.clone(), value.clone())?;
    }
    Ok(env_pairs)
}

fn should_inherit_env(key: &OsStr) -> bool {
    let key = key.as_bytes();
    key == b"TERM"
        || key == b"LANG"
        || key == b"HOME"
        || key == b"USER"
        || key == b"PATH"
        || key.starts_with(b"LC_")
}

fn set_env_pair(
    env_pairs: &mut Vec<(OsString, OsString)>,
    key: OsString,
    value: OsString,
) -> Result<()> {
    if key.is_empty() || key.as_bytes().contains(&b'=') {
        return Err(PtyError::InvalidEnvKey(key));
    }
    if let Some(existing) = env_pairs
        .iter_mut()
        .find(|(candidate, _)| candidate == &key)
    {
        existing.1 = value;
    } else {
        env_pairs.push((key, value));
    }
    Ok(())
}

fn env_pairs_to_cstrings(env_pairs: &[(OsString, OsString)]) -> Result<Vec<CString>> {
    env_pairs
        .iter()
        .map(|(key, value)| {
            let mut bytes = Vec::with_capacity(key.len() + value.len() + 1);
            bytes.extend_from_slice(key.as_bytes());
            bytes.push(b'=');
            bytes.extend_from_slice(value.as_bytes());
            CString::new(bytes).map_err(|_| PtyError::NulByte)
        })
        .collect()
}

fn resolve_command(command: &Path, env_pairs: &[(OsString, OsString)]) -> Result<PathBuf> {
    let command_bytes = command.as_os_str().as_bytes();
    if command_bytes.is_empty() {
        return Err(PtyError::BadCommand(command.to_path_buf()));
    }
    if command_bytes.contains(&b'/') {
        return executable_path(command);
    }
    let path_value = env_pairs
        .iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| OsString::from(DEFAULT_PATH));
    for dir in env::split_paths(&path_value) {
        let candidate = dir.join(command);
        if candidate.is_file() {
            return executable_path(&candidate);
        }
    }
    Err(PtyError::BadCommand(command.to_path_buf()))
}

fn executable_path(path: &Path) -> Result<PathBuf> {
    let bytes = path.as_os_str().as_bytes();
    let c_path = CString::new(bytes).map_err(|_| PtyError::NulByte)?;
    // SAFETY: c_path is a valid NUL-terminated path string for access().
    let can_execute = unsafe { libc::access(c_path.as_ptr(), libc::X_OK) } == 0;
    if can_execute {
        Ok(path.to_path_buf())
    } else {
        Err(PtyError::BadCommand(path.to_path_buf()))
    }
}

fn login_shell_path() -> PathBuf {
    // SAFETY: getpwuid returns a pointer to process-global passwd storage.
    // The value is copied into a PathBuf before returning.
    let passwd = unsafe { libc::getpwuid(libc::getuid()) };
    if !passwd.is_null() {
        // SAFETY: passwd was checked for null. pw_shell is either null or a
        // NUL-terminated C string owned by libc passwd storage.
        let shell = unsafe { (*passwd).pw_shell };
        if !shell.is_null() {
            // SAFETY: shell is non-null and NUL-terminated by the passwd API.
            let bytes = unsafe { CStr::from_ptr(shell).to_bytes() };
            if !bytes.is_empty() {
                return PathBuf::from(OsString::from_vec(bytes.to_vec()));
            }
        }
    }
    PathBuf::from(FALLBACK_LOGIN_SHELL)
}

fn cstring_from_os_str(value: &OsStr) -> Result<CString> {
    CString::new(value.as_bytes()).map_err(|_| PtyError::NulByte)
}

fn set_cloexec(fd: RawFd) -> Result<()> {
    // SAFETY: fd is expected to be open. fcntl does not retain pointers here.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    // SAFETY: fd is open and the new flags value is derived from F_GETFD.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    Ok(())
}

fn set_nonblocking(fd: RawFd) -> Result<()> {
    // SAFETY: fd is expected to be open. fcntl does not retain pointers here.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    // SAFETY: fd is open and the new flags value is derived from F_GETFL.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(PtyError::Io(io::Error::last_os_error()));
    }
    Ok(())
}

fn close_fd(fd: RawFd) {
    if fd >= 0 {
        // SAFETY: closing an fd is safe as long as no further use is made of
        // this ownership path. Callers set/forget their local fd accordingly.
        unsafe {
            libc::close(fd);
        }
    }
}

fn send_signal(pid: libc::pid_t, signal: libc::c_int) {
    if pid > 0 {
        // SAFETY: pid is the child pid returned by fork. Failure is benign
        // during cleanup because the child may have already exited.
        unsafe {
            libc::kill(pid, signal);
        }
    }
}

fn reap_child_nonblocking(pid: libc::pid_t, grace: Duration) -> Option<ExitStatus> {
    let deadline = Instant::now() + grace;
    loop {
        let mut status = 0;
        // SAFETY: pid is the child pid returned by fork.
        let result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if result == pid {
            return Some(ExitStatus::from_wait_status(status));
        }
        if result == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EINTR) {
                return None;
            }
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(1));
    }
}

fn is_would_block(error: &io::Error) -> bool {
    let raw = error.raw_os_error();
    raw == Some(libc::EAGAIN) || raw == Some(libc::EWOULDBLOCK)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn spawn_command(command: &str, args: &[&str]) -> Pty {
        Pty::spawn(PtyOptions {
            cols: 40,
            rows: 12,
            command: Some(PathBuf::from(command)),
            args: args.iter().map(OsString::from).collect(),
            cwd: None,
            env: Vec::new(),
        })
        .unwrap()
    }

    fn read_available(pty: &mut Pty, timeout: Duration) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        let mut output = Vec::new();
        let mut buf = [0_u8; 1024];
        while Instant::now() < deadline {
            match pty.read(&mut buf) {
                Ok(0) => break,
                Ok(count) => output.extend_from_slice(&buf[..count]),
                Err(PtyError::WouldBlock) => {
                    if matches!(pty.try_wait(), Ok(Some(_))) {
                        continue;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("read failed: {error}"),
            }
        }
        output
    }

    #[test]
    fn echo_exits_successfully() {
        let mut pty = spawn_command("/bin/echo", &["hello"]);
        let output = read_available(&mut pty, Duration::from_secs(2));
        let status = pty.wait_blocking().unwrap().unwrap();
        assert!(
            String::from_utf8_lossy(&output).contains("hello"),
            "output was {:?}",
            String::from_utf8_lossy(&output)
        );
        assert!(status.success());
    }

    #[test]
    fn spawn_with_many_args_and_env() {
        let args: Vec<_> = (0..50)
            .map(|index| OsString::from(format!("a{index}")))
            .collect();
        let mut shell_args = vec![
            OsString::from("-c"),
            OsString::from("printf '%s\\n' \"$LOCUS_PTY_MANY_ARGS\" \"$@\""),
            OsString::from("locus-pty-test"),
        ];
        shell_args.extend(args.iter().cloned());

        let mut pty = Pty::spawn(PtyOptions {
            cols: 120,
            rows: 24,
            command: Some(PathBuf::from("/bin/sh")),
            args: shell_args,
            cwd: None,
            env: vec![(OsString::from("LOCUS_PTY_MANY_ARGS"), OsString::from("yes"))],
        })
        .unwrap();
        let output =
            String::from_utf8_lossy(&read_available(&mut pty, Duration::from_secs(2))).to_string();
        let status = pty.wait_blocking().unwrap().unwrap();

        assert!(status.success());
        assert!(output.contains("yes"));
        for arg in &args {
            assert!(
                output.contains(arg.to_str().unwrap()),
                "missing {arg:?} in {output:?}"
            );
        }
    }

    #[test]
    fn cat_echoes_written_bytes() {
        let mut pty = spawn_command("/bin/cat", &[]);
        pty.write(b"hi\n").unwrap();
        let output = read_available(&mut pty, Duration::from_secs(1));
        assert!(String::from_utf8_lossy(&output).contains("hi"));
        let _ = pty.shutdown().unwrap();
    }

    #[test]
    fn resize_updates_master_winsize() {
        let mut pty = spawn_command("/bin/cat", &[]);
        pty.resize(100, 40).unwrap();
        assert_eq!(pty.window_size().unwrap(), (100, 40));
        let _ = pty.shutdown().unwrap();
    }

    #[test]
    fn bad_cwd_returns_error() {
        let error = Pty::spawn(PtyOptions {
            cwd: Some(PathBuf::from("/definitely/missing/locus-pty-cwd")),
            ..PtyOptions::default()
        })
        .unwrap_err();
        assert!(matches!(error, PtyError::InvalidCwd(_)));
    }

    #[test]
    fn bad_command_returns_error() {
        let error = Pty::spawn(PtyOptions {
            command: Some(PathBuf::from("/definitely/missing/locus-pty-command")),
            ..PtyOptions::default()
        })
        .unwrap_err();
        assert!(matches!(error, PtyError::BadCommand(_)));
    }

    #[test]
    fn env_is_minimal_and_allows_overrides() {
        let _guard = ENV_LOCK.lock().unwrap();
        env::set_var("LOCUS_SHOULD_NOT_LEAK_TO_PTY", "secret");
        let mut pty = Pty::spawn(PtyOptions {
            command: Some(PathBuf::from("/usr/bin/env")),
            env: vec![(OsString::from("LOCUS_ALLOWED"), OsString::from("yes"))],
            ..PtyOptions::default()
        })
        .unwrap();
        let output =
            String::from_utf8_lossy(&read_available(&mut pty, Duration::from_secs(2))).to_string();
        env::remove_var("LOCUS_SHOULD_NOT_LEAK_TO_PTY");
        assert!(output.contains("TERM=xterm-256color"));
        assert!(output.contains("COLORTERM=truecolor"));
        assert!(output.contains("LOCUS_ALLOWED=yes"));
        assert!(!output.contains("LOCUS_SHOULD_NOT_LEAK_TO_PTY"));
    }

    #[test]
    fn idle_nonblocking_read_reports_would_block() {
        let mut pty = spawn_command("/bin/cat", &[]);
        let mut buf = [0_u8; 8];
        let error = pty.read(&mut buf).unwrap_err();
        assert!(matches!(error, PtyError::WouldBlock));
        let _ = pty.shutdown().unwrap();
    }

    #[test]
    fn shutdown_is_idempotent() {
        let mut pty = spawn_command("/bin/cat", &[]);
        let _ = pty.shutdown().unwrap();
        let _ = pty.shutdown().unwrap();
        assert!(pty.master_fd() < 0);
    }

    #[test]
    fn login_shell_path_does_not_require_shell_env() {
        let shell = login_shell_path();
        assert!(!shell.as_os_str().is_empty());
    }
}
