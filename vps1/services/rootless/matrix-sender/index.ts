import { Elysia, t } from 'elysia';
import { MatrixAuth, MatrixClient, RustSdkCryptoStorageProvider, SimpleFsStorageProvider } from 'matrix-bot-sdk';
import { StoreType } from '@matrix-org/matrix-sdk-crypto-nodejs';
import canonical from 'another-json';
import nacl from 'tweetnacl';

import { SECRET_STORAGE_ALGORITHM_V1_AES, calculateKeyCheck } from 'matrix-js-sdk/lib/secret-storage.js';
import { decodeRecoveryKey } from 'matrix-js-sdk/lib/crypto-api/recovery-key.js';
import decryptSecret from 'matrix-js-sdk/lib/utils/decryptAESSecretStorageItem.js';

const storage = new SimpleFsStorageProvider('/app/data/state.json');
let token = storage.readValue('accessToken') as string;
if (!token) {
	token = (
		await new MatrixAuth(Bun.env.MATRIX_HOMESERVER!).passwordLogin(
			Bun.env.MATRIX_USERNAME!,
			Bun.env.MATRIX_PASSWORD!,
			'matrix-sender',
		)
	).accessToken;
	storage.storeValue('accessToken', token);
}

const client = new MatrixClient(
	Bun.env.MATRIX_HOMESERVER!,
	token,
	storage,
	new RustSdkCryptoStorageProvider('/app/data/crypto', StoreType.Sqlite),
);
await client.crypto.prepare(await client.getJoinedRooms());

if (!storage.readValue('verifiedAt'))
	await verify();

const app = new Elysia()
	.post('/send', async ({ body }) => {
		await client.crypto.prepare(await client.getJoinedRooms());

		return {
			event_id: await client.sendMessage(body.room_id, {
				msgtype: 'm.text',
				body: body.message,
			}),
		};
	}, {
		body: t.Object({
			room_id: t.String(),
			message: t.String(),
		}),
	})
	.listen(3000);

let stopping = false;
const stop = async () => {
	if (stopping)
		return;
	stopping = true;

	await app.stop();
	(client.crypto as any).engine.machine.close();
};
process.once('SIGINT', () => void stop());
process.once('SIGTERM', () => void stop());

function account(type: string) {
	return client.getAccountData<any>(type);
}

async function secret(name: string, keyId: string, key: Uint8Array) {
	return decryptSecret((await account(name)).encrypted[keyId], key, name);
}

function sign(object: any, userId: string, keyId: string, seed: Uint8Array) {
	const clean = structuredClone(object);
	delete clean.signatures;
	delete clean.unsigned;

	const keys = nacl.sign.keyPair.fromSeed(seed);
	const signature = nacl.sign.detached(
		new TextEncoder().encode(canonical.stringify(clean)),
		keys.secretKey,
	);

	return {
		...object,
		signatures: {
			...object.signatures,
			[userId]: {
				...object.signatures?.[userId],
				[keyId]: Buffer.from(signature)
					.toString('base64')
					.replace(/=+$/, ''),
			},
		},
	};
}

async function verify() {
	const { user_id: userId, device_id } = await client.getWhoAmI();
	const deviceId = device_id ?? client.crypto.clientDeviceId;
	const recoveryKey = decodeRecoveryKey(Bun.env.MATRIX_RECOVERY_KEY!);

	const keyId = (await account('m.secret_storage.default_key')).key;
	const keyInfo = await account(`m.secret_storage.key.${keyId}`,);
	if (keyInfo.algorithm !== SECRET_STORAGE_ALGORITHM_V1_AES)
		throw new Error('unsupported secret storage');

	const check = await calculateKeyCheck(recoveryKey, keyInfo.iv);
	if (keyInfo.mac && check.mac.replace(/=+$/, '') !== keyInfo.mac.replace(/=+$/, ''))
		throw new Error('bad recovery key');

	const seed = new Uint8Array(
		Buffer.from(
			await secret('m.cross_signing.self_signing', keyId, recoveryKey),
			'base64',
		),
	);

	const query = await client.doRequest(
		'POST',
		'/_matrix/client/v3/keys/query',
		null,
		{
			device_keys: {
				[userId]: [deviceId],
			},
		},
	);

	const device = query.device_keys[userId][deviceId];
	const selfSigning = query.self_signing_keys[userId];
	const signingKeyId = Object.keys(selfSigning.keys).find(
		key => key.startsWith('ed25519:')
	)!;

	await client.doRequest(
		'POST',
		'/_matrix/client/v3/keys/signatures/upload',
		null,
		{
			[userId]: {
				[deviceId]: sign(
					device,
					userId,
					signingKeyId,
					seed,
				),
			},
		},
	);

	storage.storeValue('verifiedAt', new Date().toISOString());
}
