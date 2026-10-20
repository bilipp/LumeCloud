// Client IP keying: IPv4 as-is, IPv6 grouped by /64 (PROTOCOL.md §5).

/** Expands an IPv6 address to 8 groups, or returns null when malformed. */
function expandIPv6(addr: string): string[] | null {
	let s = addr.toLowerCase();
	const zone = s.indexOf("%");
	if (zone >= 0) s = s.slice(0, zone);

	// IPv4-mapped / embedded tail (e.g. ::ffff:1.2.3.4) becomes two groups.
	const v4 = /^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
	if (v4 !== null) {
		const octets = v4.slice(2, 6).map(Number);
		if (octets.some((o) => o > 255)) return null;
		const [a = 0, b = 0, c = 0, d = 0] = octets;
		s = `${v4[1]}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
	}

	const halves = s.split("::");
	if (halves.length > 2) return null;
	const head = halves[0] ? halves[0].split(":") : [];
	const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
	const missing = 8 - head.length - tail.length;
	if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
	const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...tail];
	if (groups.length !== 8 || groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
	return groups.map((g) => g.padStart(4, "0"));
}

/** The key used for per-IP limits: IPv4 address, or the IPv6 /64 prefix. */
export function clientIpKey(request: Request): string {
	const raw = (request.headers.get("cf-connecting-ip") ?? "").trim();
	if (raw === "") return "unknown";
	if (raw.includes(":")) {
		const groups = expandIPv6(raw);
		if (groups === null) return "invalid";
		// IPv4-mapped addresses are really IPv4.
		if (groups.slice(0, 5).every((g) => g === "0000") && groups[5] === "ffff") {
			const hi = parseInt(groups[6] ?? "0", 16);
			const lo = parseInt(groups[7] ?? "0", 16);
			return `${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`;
		}
		return `${groups.slice(0, 4).join(":")}::/64`;
	}
	return raw;
}
