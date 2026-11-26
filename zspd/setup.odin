package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "../host"

// What makes devices' names and addresses work for every application on this machine, done once, as root: and
// nothing else. Each step is said before it is done; --dry-run says them only; --undo takes every one of them back.
//
//   Linux    names: a dummy network interface, zsp0, which carries nothing, has one private IPv6 address of its own
//                   (systemd-resolved heeds only an interface with one), and tells systemd-resolved to ask the node
//                   for names under the suffix, and for the addresses the other way, and for nothing else.
//            addresses: an nftables rule sending this machine's TCP connections to the devices' addresses to the
//                   node's one socket for them, which takes no port from anything else here (see catch_linux.odin).
//            A systemd unit, zsp-names, makes both again at boot, and takes them away when stopped.
//   macOS    names: /etc/resolver files for the suffix and the addresses the other way.
//            addresses: lo0 aliases, 127.a.b.1 onwards, one per device, made at boot by a launchd daemon.
//   Windows  names: a Name Resolution Policy Table rule for the suffix and the addresses the other way.
//            addresses: none needed: all of 127/8 is this machine's already.

SETUP_UNIT :: "/etc/systemd/system/zsp-names.service"
SETUP_PLIST :: "/Library/LaunchDaemons/sh.zeron.zsp-names.plist"
SETUP_LABEL :: "sh.zeron.zsp-names"
SETUP_COMMENT :: "zspd setup"

Setup :: struct {
	suffix:   string,
	loopback: [2]byte,
	dns:      net.Endpoint,
	catch_at: net.Endpoint,
	devices:  int, // macOS: addresses made, one per device
	dry:      bool,
}

setup :: proc(args: []string) -> int {
	s := Setup {
		suffix   = host.NAMES,
		loopback = {77, 0},
		catch_at = {net.IP4_Loopback, 5054},
		devices  = 254,
	}
	undo := false
	dns := ""
	for a in args {
		name, _, value := strings.partition(a, "=")
		switch name {
		case "--undo":
			undo = true
		case "--dry-run":
			s.dry = true
		case "--names":
			if !host.suffix_valid(value) {
				return usage()
			}
			s.suffix = value
		case "--loopback":
			base, ok := parse_loopback(value)
			if !ok {
				return usage()
			}
			s.loopback = base
		case "--dns":
			dns = value
		case "--catch":
			ep, ok := net.parse_endpoint(value)
			if !ok || ep.port == 0 {
				return usage() // the system is told the port: it must be one
			}
			s.catch_at = ep
		case "--devices":
			n, ok := parse_int(value)
			if !ok || n < 1 || n > 65533 {
				return usage()
			}
			s.devices = n
		case:
			return usage()
		}
	}
	if int(s.loopback[1]) + (s.devices + 1) / 256 > 255 {
		say(os.stderr, "so many devices have no addresses past 127.", fmt.tprint(s.loopback[0]), ".255.255: fewer, or a lower --loopback\n")
		return 2
	}
	s.dns = {net.IP4_Address{127, s.loopback[0], s.loopback[1], 1}, DNS_PORT}
	if dns != "" {
		ep, ok := net.parse_endpoint(dns)
		if !ok || ep.port == 0 {
			return usage()
		}
		s.dns = ep
	}
	if !s.dry && !is_root() {
		say(os.stderr, "zspd setup changes how this machine resolves names and reaches addresses: run it as root",
			" (sudo zspd setup), or see what it would do with --dry-run\n" when ODIN_OS != .Windows else " (from an Administrator prompt), or see what it would do with --dry-run\n")
		return 1
	}
	ok := setup_undo(&s) if undo else setup_do(&s)
	if !ok {
		say(os.stderr, "setup failed; what was done is as said above, and zspd setup --undo takes it back\n")
		return 1
	}
	return 0
}

DNS_PORT :: 5053 when ODIN_OS == .Linux || ODIN_OS == .FreeBSD else 53

// Says a step, and unless this is a dry run, takes it.
@(private = "file")
step :: proc(s: ^Setup, what: string, argv: ..string) -> bool {
	say(os.stdout, "  ", what, "\n")
	if len(argv) > 0 {
		say(os.stdout, "    $ ", strings.join(argv, " ", context.temp_allocator), "\n")
	}
	if s.dry || len(argv) == 0 {
		return true
	}
	state, out, errs, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		say(os.stderr, "    failed: ", strings.trim_space(string(errs)), strings.trim_space(string(out)), "\n" if err == nil else fmt.tprint(" ", err, "\n"))
		return false
	}
	return true
}

@(private = "file")
write :: proc(s: ^Setup, path, text: string) -> bool {
	say(os.stdout, "  write ", path, ":\n")
	for line in strings.split_lines(strings.trim_right(text, "\n"), context.temp_allocator) {
		say(os.stdout, "    | ", line, "\n")
	}
	if s.dry {
		return true
	}
	if err := os.make_directory_all(filepath_dir(path)); err != nil && !os.is_dir(filepath_dir(path)) {
		return false
	}
	// Readable by all, as the system's own are: what reads it need not be root.
	return host.save(path, transmute([]byte)text) && os.chmod(path, {.Read_User, .Write_User, .Read_Group, .Read_Other}) == nil
}

@(private = "file")
remove :: proc(s: ^Setup, path: string) {
	if !os.exists(path) {
		return
	}
	say(os.stdout, "  remove ", path, "\n")
	if !s.dry {
		os.remove(path)
	}
}

@(private = "file")
filepath_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[:i] if i > 0 else "/"
}

@(private = "file")
reverse_zone :: proc(s: ^Setup) -> string {
	return fmt.tprintf("%d.127.in-addr.arpa", s.loopback[0])
}

@(private = "file")
ip :: proc(a: net.Address) -> string {
	return net.address_to_string(a, context.temp_allocator)
}

when ODIN_OS == .Linux {
	@(private = "file")
	linux_script :: proc(s: ^Setup, ula: string) -> (start, stop: string) {
		base := s.loopback
		start = fmt.tprintf(
			"ip link add zsp0 type dummy 2>/dev/null; ip link set zsp0 up && ip addr replace %s/128 dev zsp0 nodad && " +
			"resolvectl dns zsp0 %s && resolvectl domain zsp0 '~%s' '~%s' && resolvectl default-route zsp0 false && " +
			"{{ nft delete table ip zsp 2>/dev/null; nft 'add table ip zsp; add chain ip zsp output {{ type nat hook output priority -100; policy accept; }}; " +
			"add rule ip zsp output ip daddr 127.%d.%d.2-127.%d.255.255 meta l4proto tcp redirect to :%d'; }}",
			ula, net.endpoint_to_string(s.dns, context.temp_allocator), s.suffix, reverse_zone(s), base[0], base[1], base[0], s.catch_at.port,
		)
		stop = "nft delete table ip zsp 2>/dev/null; ip link del zsp0 2>/dev/null; true"
		return
	}

	@(private = "file")
	setup_do :: proc(s: ^Setup) -> bool {
		if !os.exists("/run/systemd/resolve") {
			say(os.stderr, "systemd-resolved is not running here, and it is what zspd setup tells about names. With another resolver,\n",
				"send it ", s.suffix, " and ", reverse_zone(s), " at ", net.endpoint_to_string(s.dns, context.temp_allocator), "; for example dnsmasq's server=/", s.suffix, "/", ip(s.dns.address), "#", fmt.tprint(s.dns.port), "\n")
			return false
		}
		if s.catch_at.address != net.IP4_Loopback {
			say(os.stderr, "on Linux the node's socket for devices' addresses must be at 127.0.0.1, where the kernel sends them\n")
			return false
		}
		// A private IPv6 address of the interface's own (RFC 4193), drawn now: resolved heeds no interface without one.
		ula := draw_ula()
		start, stop := linux_script(s, ula)
		say(os.stdout, "Names under ", s.suffix, " and addresses 127.", fmt.tprint(s.loopback[0]), ".*.* for every application here:\n")
		unit := fmt.tprintf(
			"# Made by zspd setup; zspd setup --undo takes it away.\n" +
			"# zsp0 carries nothing: it tells systemd-resolved to ask the node for %s alone; and an nftables rule sends\n" +
			"# connections to devices' addresses 127.%d.*.* to the node's one socket for them, %s.\n" +
			"[Unit]\nDescription=Devices of a zsp space, by name and address, here\nAfter=systemd-resolved.service\nWants=systemd-resolved.service\n\n" +
			"[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/sh -c \"%s\"\nExecStop=/bin/sh -c \"%s\"\n\n" +
			"[Install]\nWantedBy=multi-user.target\n",
			s.suffix, s.loopback[0], net.endpoint_to_string(s.catch_at, context.temp_allocator), start, stop,
		)
		write(s, SETUP_UNIT, unit) or_return
		step(s, "have systemd read it", "systemctl", "daemon-reload") or_return
		step(s, "make them now, and at every boot", "systemctl", "enable", "--now", "zsp-names.service") or_return
		step(s, "and again now, if they were already", "systemctl", "restart", "zsp-names.service") or_return
		say(os.stdout, "Done. zspd run with the same --names, --loopback, --dns and --catch as this (or none) answers for them.\n")
		return true
	}

	@(private = "file")
	setup_undo :: proc(s: ^Setup) -> bool {
		say(os.stdout, "Taking back what zspd setup did:\n")
		if os.exists(SETUP_UNIT) {
			step(s, "stop it, and at boot", "systemctl", "disable", "--now", "zsp-names.service")
			remove(s, SETUP_UNIT)
			step(s, "have systemd forget it", "systemctl", "daemon-reload")
		}
		_, stop := linux_script(s, "")
		step(s, "and whatever is left of it", "/bin/sh", "-c", stop)
		return true
	}

	@(private = "file")
	is_root :: proc() -> bool {
		return linux_getuid() == 0
	}
} else when ODIN_OS == .Darwin {
	@(private = "file")
	aliases :: proc(s: ^Setup, add: bool) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "for i in $(seq 1 ")
		strings.write_int(&b, s.devices + 1)
		strings.write_string(&b, "); do /sbin/ifconfig lo0 ")
		strings.write_string(&b, "alias" if add else "-alias")
		fmt.sbprintf(&b, " 127.%d.$(( %d + i / 256 )).$(( i %% 256 ))", s.loopback[0], s.loopback[1])
		strings.write_string(&b, " 255.255.255.255" if add else "")
		strings.write_string(&b, " 2>/dev/null; done; true")
		return strings.to_string(b)
	}

	@(private = "file")
	resolver :: proc(s: ^Setup) -> string {
		return fmt.tprintf("# Made by zspd setup; zspd setup --undo takes it away.\nnameserver %s\nport %d\n", ip(s.dns.address), s.dns.port)
	}

	@(private = "file")
	setup_do :: proc(s: ^Setup) -> bool {
		say(os.stdout, "Names under ", s.suffix, " and addresses for ", fmt.tprint(s.devices), " devices, for every application here:\n")
		write(s, strings.concatenate({"/etc/resolver/", s.suffix}, context.temp_allocator), resolver(s)) or_return
		write(s, strings.concatenate({"/etc/resolver/", reverse_zone(s)}, context.temp_allocator), resolver(s)) or_return
		plist := fmt.tprintf(
			`<?xml version="1.0" encoding="UTF-8"?>` + "\n" +
			`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` + "\n" +
			"<!-- Made by zspd setup; zspd setup --undo takes it away. Addresses of a zsp space's devices, here, at boot. -->\n" +
			"<!-- zsp-aliases %d %d %d -->\n" +
			"<plist version=\"1.0\"><dict>\n<key>Label</key><string>%s</string>\n" +
			"<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>%s</string></array>\n" +
			"<key>RunAtLoad</key><true/>\n</dict></plist>\n",
			s.loopback[0], s.loopback[1], s.devices, SETUP_LABEL, aliases(s, true),
		)
		write(s, SETUP_PLIST, plist) or_return
		step(s, "forget any earlier one", "/bin/sh", "-c", "launchctl bootout system/" + SETUP_LABEL + " 2>/dev/null; true")
		step(s, "make the addresses now, and at every boot", "launchctl", "bootstrap", "system", SETUP_PLIST) or_return
		say(os.stdout, "Done. zspd run with the same --names, --loopback and --dns as this (or none) answers for them.\n")
		return true
	}

	@(private = "file")
	setup_undo :: proc(s: ^Setup) -> bool {
		say(os.stdout, "Taking back what zspd setup did:\n")
		// What it was set up with is found where it was written, not taken from what --undo is told.
		if plist, err := os.read_entire_file(SETUP_PLIST, context.temp_allocator); err == nil {
			if _, _, rest := strings.partition(string(plist), "<!-- zsp-aliases "); rest != "" {
				said, _, _ := strings.partition(rest, " -->")
				words := strings.fields(said, context.temp_allocator)
				if len(words) == 3 {
					number :: proc(w: string) -> (n: int, ok: bool) {
						if w == "" || len(w) > 5 {
							return
						}
						for c in transmute([]byte)w {
							if c < '0' || c > '9' {
								return
							}
							n = n * 10 + int(c - '0')
						}
						return n, true
					}
					a, aok := number(words[0])
					b, bok := number(words[1])
					n, nok := number(words[2])
					if aok && bok && nok && a >= 0 && a <= 255 && b >= 0 && b <= 255 && n > 0 && n <= 65533 {
						s.loopback, s.devices = {byte(a), byte(b)}, n
					}
				}
			}
		}
		step(s, "stop making the addresses", "/bin/sh", "-c", "launchctl bootout system/" + SETUP_LABEL + " 2>/dev/null; true")
		remove(s, SETUP_PLIST)
		step(s, "take the addresses away", "/bin/sh", "-c", aliases(s, false))
		if files, err := os.read_all_directory_by_path("/etc/resolver", context.temp_allocator); err == nil {
			for f in files {
				text, rerr := os.read_entire_file(f.fullpath, context.temp_allocator)
				if rerr == nil && strings.has_prefix(string(text), "# Made by zspd setup") {
					remove(s, f.fullpath)
				}
			}
		}
		return true
	}

	@(private = "file")
	is_root :: proc() -> bool {
		return darwin_getuid() == 0
	}
} else when ODIN_OS == .Windows {
	@(private = "file")
	setup_do :: proc(s: ^Setup) -> bool {
		if s.dns.port != 53 {
			say(os.stderr, "Windows asks name servers at port 53 only: run the node with --dns at port 53\n")
			return false
		}
		say(os.stdout, "Names under ", s.suffix, " for every application here (addresses need nothing: all of 127/8 is this machine's):\n")
		rule := fmt.tprintf(
			"Get-DnsClientNrptRule | Where-Object Comment -eq '%s' | Remove-DnsClientNrptRule -Force; " +
			"Add-DnsClientNrptRule -Namespace '.%s','.%s' -NameServers '%s' -Comment '%s'; Clear-DnsClientCache",
			SETUP_COMMENT, s.suffix, reverse_zone(s), ip(s.dns.address), SETUP_COMMENT,
		)
		step(s, "ask the node for those names, and for nothing else", "powershell", "-NoProfile", "-NonInteractive", "-Command", rule) or_return
		say(os.stdout, "Done. zspd run with the same --names, --loopback and --dns as this (or none) answers for them.\n")
		return true
	}

	@(private = "file")
	setup_undo :: proc(s: ^Setup) -> bool {
		say(os.stdout, "Taking back what zspd setup did:\n")
		rule := fmt.tprintf("Get-DnsClientNrptRule | Where-Object Comment -eq '%s' | Remove-DnsClientNrptRule -Force; Clear-DnsClientCache", SETUP_COMMENT)
		return step(s, "stop asking the node for names", "powershell", "-NoProfile", "-NonInteractive", "-Command", rule)
	}

	@(private = "file")
	is_root :: proc() -> bool {
		// Whoever may change the resolution policy is an administrator: it is found out by trying, as nothing else
		// says so as plainly.
		state, _, _, err := os.process_exec({command = {"net", "session"}}, context.temp_allocator)
		return err == nil && state.exited && state.exit_code == 0
	}
} else {
	@(private = "file")
	setup_do :: proc(s: ^Setup) -> bool {
		say(os.stderr, "zspd setup knows Linux, macOS and Windows; here, send ", s.suffix, " to ", net.endpoint_to_string(s.dns, context.temp_allocator), " yourself\n")
		return false
	}

	@(private = "file")
	setup_undo :: proc(s: ^Setup) -> bool {
		return true
	}

	@(private = "file")
	is_root :: proc() -> bool {
		return true
	}
}
