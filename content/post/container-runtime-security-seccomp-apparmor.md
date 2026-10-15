---
title: "Container Runtime Security: seccomp and AppArmor"
date: 2026-05-25T11:20:00-04:00
draft: false
tags: [backend, security, containers, linux, seccomp]
---

## Containers are not a security boundary by default

A container is not a virtual machine. It is a normal Linux process whose view of the system has been narrowed by namespaces (what it can *see*) and cgroups (what it can *use*). Crucially, every process in every container talks to the **same host kernel**. A single exploitable kernel bug reachable through a syscall is a path out of the container.

That shared kernel is why runtime security matters. Namespaces isolate resources; they do not reduce the kernel's attack surface. The two mechanisms that actually shrink what a container can ask the kernel to do are **seccomp** (filters which syscalls are allowed) and **Linux Security Modules** like **AppArmor** and SELinux (mediate what resources those syscalls may touch). They operate at different layers and are most effective together.

{{< mermaid >}}
graph TD
    A["Containerized process"] --> B["seccomp-BPF filter"]
    B -->|"syscall allowed"| C["Capabilities check"]
    B -->|"syscall denied"| X["EPERM / SIGSYS / kill"]
    C -->|"capability present"| D["LSM hook (AppArmor / SELinux)"]
    C -->|"missing capability"| X
    D -->|"profile permits"| E["Kernel performs operation"]
    D -->|"profile denies"| X
{{< /mermaid >}}

This layered ordering matters: seccomp gates the *syscall itself*, capability checks gate *privileged operations*, and the LSM gates *which objects* the operation may act on. A request must pass all three.

## seccomp: filtering the syscall surface

The Linux kernel exposes roughly 350+ system calls. A typical web application uses a few dozen. Every syscall the application never legitimately needs is dead weight on the attack surface — `keyctl`, `ptrace`, `mount`, `bpf`, `userfaultfd`, and others have all been used in real escape chains. seccomp (secure computing mode) lets you install a BPF program that inspects each syscall and decides its fate.

A seccomp profile is a JSON document mapping syscalls to actions. The runtime compiles it into a BPF filter attached to the process so the kernel evaluates it on every syscall entry.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["read", "write", "openat", "close", "fstat",
                "mmap", "mprotect", "brk", "rt_sigaction",
                "futex", "epoll_wait", "accept4"],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["ptrace", "mount", "reboot", "keyctl", "bpf"],
      "action": "SCMP_ACT_KILL"
    }
  ]
}
```

The available actions form a spectrum:

| Action | Effect |
| --- | --- |
| `SCMP_ACT_ALLOW` | Permit the syscall |
| `SCMP_ACT_ERRNO` | Deny, return an errno (e.g. `EPERM`) — app sees a failure it can handle |
| `SCMP_ACT_LOG` | Allow but log — invaluable for building profiles |
| `SCMP_ACT_TRACE` | Hand off to a tracer (`ptrace`) for userspace policy |
| `SCMP_ACT_KILL` | Terminate the thread/process with SIGSYS |

The choice between `ERRNO` and `KILL` is a real design decision. Returning an errno is friendlier — well-behaved code degrades gracefully (for example, `glibc` falls back to an older stat syscall when `statx` returns `ENOSYS`). Killing is stricter and surfaces violations loudly but can crash an app that probes for optional syscalls.

### The default profiles already do a lot

Docker and Podman ship a default seccomp profile that blocks around 40+ dangerous syscalls while allowing the common majority. This default alone prevents a large class of exploits. The most common operational footgun is disabling it:

```bash
# This removes the seccomp profile entirely — almost never what you want
docker run --security-opt seccomp=unconfined myimage

# Apply a tailored profile instead
docker run --security-opt seccomp=/etc/docker/seccomp/myapp.json myimage
```

In Kubernetes, the equivalent is the `seccompProfile` in the pod or container security context. As of recent versions, `RuntimeDefault` should be the baseline for every workload:

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault   # use the container runtime's default profile
```

### Building a tight profile empirically

Writing an allowlist by hand is error-prone. The practical workflow is to run the workload under a logging profile and record what it actually calls:

```bash
# Trace syscalls during a representative run
strace -f -qq -e trace=all -o trace.log ./run-integration-tests.sh
# Extract the unique syscall names
grep -oE '^[0-9]+ +[a-z_0-9]+\(' trace.log \
  | sed -E 's/^[0-9]+ +//; s/\(//' | sort -u
```

Tools like `oci-seccomp-bpf-hook` (Podman), Inspektor Gadget's `advise seccomp-profile`, or the Security Profiles Operator in Kubernetes can auto-generate a profile from observed behavior. Always exercise the full code path — error handling, signal handling, graceful shutdown — because rarely-hit branches make rarely-hit syscalls, and a profile that is too tight fails in production rather than testing.

## AppArmor: mediating resource access by path

seccomp answers "which syscalls?" but not "which files, which capabilities, which network operations?" That is the job of a Linux Security Module. **AppArmor** is the path-based LSM common on Debian/Ubuntu; **SELinux** is the label-based equivalent on RHEL/Fedora. They hook the same kernel mediation points; AppArmor's profiles are generally easier to read and reason about.

An AppArmor profile confines a program to an explicit set of file paths, capabilities, and network rules. Anything not granted is denied.

```
#include <tunables/global>

profile myapp-confined flags=(attach_disconnected) {
  #include <abstractions/base>

  # Read-only access to the app and its config
  /app/bin/server        rix,
  /app/config/**         r,

  # A single writable working directory
  /var/lib/myapp/**      rw,

  # Explicitly deny the dangerous bits
  deny /etc/shadow       rwklx,
  deny /proc/sysrq-trigger w,
  deny mount,
  deny ptrace,

  # Only the capabilities actually needed
  capability net_bind_service,
  network tcp,
}
```

The permission flags (`r` read, `w` write, `x` execute, `m` memory-map executable, `k` lock, `l` link) give fine control, and `deny` rules override defaults. The result is that even if an attacker achieves code execution inside the container, AppArmor still blocks reads of `/etc/shadow`, writes to `/proc`, and mounting filesystems — operations that seccomp might allow as bare syscalls but that should never touch sensitive objects.

Applying a profile:

```bash
# Load the profile into the kernel
apparmor_parser -r -W /etc/apparmor.d/myapp-confined

# Run the container under it
docker run --security-opt apparmor=myapp-confined myimage
```

AppArmor supports **complain mode**, the analog of seccomp's `SCMP_ACT_LOG`: it logs what *would* be denied without enforcing, letting you build a profile from real behavior before flipping to enforce mode.

```bash
aa-complain /etc/apparmor.d/myapp-confined   # observe
# ... run workload, inspect /var/log/audit/audit.log or dmesg ...
aa-enforce /etc/apparmor.d/myapp-confined    # enforce
```

## Why you want both, plus the rest of the stack

seccomp and AppArmor cover overlapping-but-distinct ground, and defense in depth means stacking them with the other runtime controls.

| Control | Question it answers |
| --- | --- |
| seccomp | Which syscalls may this process make at all? |
| Capabilities | Which privileged operations may it perform? |
| AppArmor / SELinux | Which files / sockets / objects may those operations touch? |
| Namespaces | What can the process see? |
| cgroups | How much resource can it consume? |
| Read-only rootfs | Can it modify its own image? |

A concrete hardened Kubernetes container security context brings several of these together:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  allowPrivilegeEscalation: false   # blocks setuid escalation
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]                   # start from zero
    add: ["NET_BIND_SERVICE"]       # add back only what is needed
  seccompProfile:
    type: RuntimeDefault
```

Dropping `ALL` capabilities and adding back only the needed ones is one of the highest-value, lowest-effort hardening steps available — most applications need none. `allowPrivilegeEscalation: false` sets the `no_new_privs` bit, which both prevents setuid binaries from gaining privilege *and* is a prerequisite for an unprivileged process to install a seccomp filter.

## Operational pitfalls

- **Profiles drift from the code.** A profile generated for v1.2 of an app may break when v1.3 adds a feature that calls a new syscall or opens a new path. Regenerate and test profiles as part of CI, not as a one-time exercise.
- **Too tight fails in production.** Rare code paths — error handlers, crash dumps, TLS renegotiation, DNS fallback — use rare syscalls. A profile validated only against the happy path will deny something during an incident, which is the worst possible time.
- **`unconfined` creeps in.** A debugging session adds `seccomp=unconfined` or `--privileged`, and it ships to production. Audit running workloads for these escape hatches; a `--privileged` container has effectively no runtime confinement at all.
- **LSM availability is host-dependent.** AppArmor must be enabled in the host kernel and loaded; on a SELinux host the AppArmor option silently does nothing. Know your base OS and standardize.

## Summary

Containers share the host kernel, so the real runtime security boundary is the set of syscalls and resources a containerized process can reach — not the namespace wall. seccomp shrinks the syscall attack surface to what the application provably needs; AppArmor (or SELinux) constrains which files, capabilities, and sockets those calls may act on; capabilities and a read-only rootfs close the remaining gaps. None of them alone is sufficient, and all of them are most effective when generated empirically from observed behavior, tested against failure paths, and kept in sync with the code through CI. Start from `RuntimeDefault` seccomp, `drop: ALL` capabilities, and a path-confined LSM profile, then loosen deliberately rather than starting from `unconfined` and hoping.
