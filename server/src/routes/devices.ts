// /v1/devices — register, list and revoke devices (PROTOCOL.md §4.2).

import { notFound, unwrap } from "../lib/errors";
import { json, noContent, readJsonObject } from "../lib/http";
import { MAX_SMALL_BODY_BYTES } from "../lib/limits";
import { isUuid, requireDeviceName, requirePlatform, requireString, requireUuid } from "../lib/validate";
import { authenticate } from "./context";

export async function registerDevice(request: Request, env: Env): Promise<Response> {
	// X-Lume-Device is optional here: the body carries the id being registered.
	const { account, auth } = await authenticate(request, env, false);
	const body = await readJsonObject(request, MAX_SMALL_BODY_BYTES);
	const input = {
		id: requireUuid(requireString(body, "id"), '"id"'),
		name: requireDeviceName(body, "name"),
		platform: requirePlatform(body, "platform"),
	};
	return json(unwrap(await account.registerDevice(auth, input)));
}

export async function listDevices(request: Request, env: Env): Promise<Response> {
	const { account, auth } = await authenticate(request, env, true);
	return json({ devices: unwrap(await account.listDevices(auth)) });
}

export async function revokeDevice(request: Request, env: Env, rawId: string): Promise<Response> {
	const { account, auth } = await authenticate(request, env, true);
	const id = decodeURIComponent(rawId);
	if (!isUuid(id)) throw notFound("Unknown device");
	unwrap(await account.revokeDevice(auth, id.toUpperCase()));
	return noContent();
}
