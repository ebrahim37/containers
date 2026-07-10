import { Elysia, t } from 'elysia';
import { MatrixAuth, MatrixClient, RustSdkCryptoStorageProvider, SimpleFsStorageProvider } from 'matrix-bot-sdk';
import { StoreType } from '@matrix-org/matrix-sdk-crypto-nodejs';
import nacl from 'tweetnacl';
import canonical from 'another-json';

import { SECRET_STORAGE_ALGORITHM_V1_AES, calculateKeyCheck } from 'matrix-js-sdk/lib/secret-storage.js';
import { decodeRecoveryKey } from 'matrix-js-sdk/lib/crypto-api/recovery-key.js';
import decryptSecret from 'matrix-js-sdk/lib/utils/decryptAESSecretStorageItem.js';

const storage = new SimpleFsStorageProvider('/app/data/state.json');
const firstLaunch = !storage.readValue('accessToken');
const token = await getToken();

const client = new MatrixClient(
	process.env.MATRIX_HOMESERVER!,
	token,
	storage,
	new RustSdkCryptoStorageProvider('/app/data/crypto', StoreType.Sqlite),
);

await client.crypto.prepare(await client.getJoinedRooms());

if (firstLaunch)
	await verifyThisDevice();

const app = new Elysia()
	.post('/send', async ({ body, status }) => {
		const rooms = await client.getJoinedRooms();

		if (!rooms.includes(body.roomID))
			return status(403, { error: 'not joined to room' });

		await client.crypto.prepare(rooms);

		if (!(await client.crypto.isRoomEncrypted(body.roomID)))
			return status(400, { error: 'room is not encrypted' });

		return {
			eventID: await client.sendMessage(body.roomID, {
				msgtype: 'm.text',
				body: body.message,
			}),
		};
	}, {
		body: t.Object({
			roomID: t.String(),
			message: t.String(),
		}),
	}).listen(8080);

let stopping = false;

async function stopApp() {
	if (stopping)
		return;

	stopping = true;

	try {
		await app.stop();

		const stopClient = (client as unknown as { stop?: () => unknown }).stop;
		if (typeof stopClient === 'function')
			await stopClient.call(client);

		process.exitCode = 0;
	} catch (error) {
		console.error(error);
		process.exitCode = 1;
	}
}

process.once('SIGINT', () => void stopApp());
process.once('SIGTERM', () => void stopApp());

async function getToken() {
	const existing = storage.readValue('accessToken');
	if (existing)
		return existing;

	const { accessToken } = await new MatrixAuth(process.env.MATRIX_HOMESERVER!)
		.passwordLogin(process.env.MATRIX_USERNAME!, process.env.MATRIX_PASSWORD!);
	storage.storeValue('accessToken', accessToken);
	return accessToken;
}

async function accountData(userId: string, type: string) {
	return client.doRequest(
		'GET',
		`/_matrix/client/v3/user/${encodeURIComponent(userId)}/account_data/${encodeURIComponent(type)}`,
	);
}

async function secret(userId: string, name: string, keyId: string, key: Uint8Array<ArrayBuffer>) {
	const item = (await accountData(userId, name)).encrypted?.[keyId];
	return decryptSecret(item, key, name);
}

function sign(obj: any, userId: string, keyId: string, seed: Uint8Array) {
	const clean = JSON.parse(JSON.stringify(obj));
	delete clean.signatures;
	delete clean.unsigned;

	const kp = nacl.sign.keyPair.fromSeed(seed);
	const sig = nacl.sign.detached(
		new TextEncoder().encode(canonical.stringify(clean)),
		kp.secretKey,
	);

	return {
		...obj,
		signatures: {
			...obj.signatures,
			[userId]: {
				...obj.signatures?.[userId],
				[keyId]: Buffer.from(sig).toString('base64').replace(/=+$/, ''),
			},
		},
	};
}

function b64(s: string) {
	return new Uint8Array(Buffer.from(s + '='.repeat((4 - (s.length % 4)) % 4), 'base64'));
}

async function verifyThisDevice() {
	const { user_id: userId, device_id } = await client.doRequest(
		'GET',
		'/_matrix/client/v3/account/whoami',
	);

	const deviceId = device_id ?? client.crypto.clientDeviceId;
	const storageKey = decodeRecoveryKey(process.env.MATRIX_RECOVERY_KEY!.trim());

	const defaultKeyId = (await accountData(userId, 'm.secret_storage.default_key')).key;
	const keyInfo = await accountData(userId, `m.secret_storage.key.${defaultKeyId}`);

	if (keyInfo.algorithm !== SECRET_STORAGE_ALGORITHM_V1_AES)
		throw new Error(`unsupported secret storage: ${keyInfo.algorithm}`);

	const check = await calculateKeyCheck(storageKey, keyInfo.iv);
	if (keyInfo.mac && check.mac.replace(/=+$/, '') !== keyInfo.mac.replace(/=+$/, ''))
		throw new Error('bad RECOVERY_KEY');

	const seed = b64(await secret(userId, 'm.cross_signing.self_signing', defaultKeyId, storageKey));

	const query = await client.doRequest(
		'POST',
		'/_matrix/client/v3/keys/query',
		null,
		{ device_keys: { [userId]: [deviceId] } },
	);

	const device = query.device_keys[userId][deviceId];
	const selfSigning = query.self_signing_keys[userId];
	const signingKeyId = Object.keys(selfSigning.keys).find((k) => k.startsWith('ed25519:'))!;

	await client.doRequest(
		'POST',
		'/_matrix/client/v3/keys/signatures/upload',
		null,
		{
			[userId]: {
				[deviceId]: sign(device, userId, signingKeyId, seed),
			},
		},
	);
	storage.storeValue('verifiedAt', new Date().toISOString());
}
