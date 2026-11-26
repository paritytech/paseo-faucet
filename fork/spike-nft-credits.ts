import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Transaction } from 'polkadot-api';
import { getFakeTxCreator } from 'polkadot-api/tx-creator';
import { type Hex, bytesToHex } from 'viem';
import {
  ALICE,
  type Chain,
  type ChainEvent,
  type ChainName,
  call,
  constant,
  contractAccount,
  deploy,
  eventsSince,
  head,
  json,
  loadArtifact,
  open,
  ss58,
  query,
  submit,
  transferPas,
  untilEvent,
  xcmCodec,
} from './lib.ts';

const PAS = 10n ** 10n;
const FAUCET_GAME_BASE = 0x8000_0000;

async function startPair() {
  process.env.LOG_LEVEL ??= 'warn';
  const { BuildBlockMode, connectParachains, destroyWorker, fetchConfig, setupWithServer } = await import(
    '@acala-network/chopsticks'
  );
  const cache = fileURLToPath(new URL('.cache/', import.meta.url));
  mkdirSync(cache, { recursive: true });
  const names: [ChainName, string][] = [
    ['assetHubNext', 'asset-hub-next'],
    ['peopleNext', 'people-next'],
  ];
  const servers: Awaited<ReturnType<typeof setupWithServer>>[] = [];
  for (const [name, file] of names) {
    const config = await fetchConfig(fileURLToPath(new URL(`chopsticks/${file}.yml`, import.meta.url)));
    servers.push(
      await setupWithServer({ ...config, 'build-block-mode': BuildBlockMode.Manual, db: `${cache}spike-${name}.sqlite` }),
    );
  }
  await connectParachains(servers.map((s) => s.chain));
  const chains: Chain[] = [];
  for (const [i, [name]] of names.entries()) {
    const connected = await open(`ws://127.0.0.1:${Number(servers[i]!.addr.split(':').pop())}`);
    const base = { ...connected, name, source: {}, api: connected.client.getUnsafeApi() };
    const version = constant(base, 'System', 'Version');
    chains.push({
      ...base,
      forkedAt: await head(base),
      paraId: await query(base, 'ParachainInfo', 'ParachainId'),
      specName: version.spec_name,
      specVersion: version.spec_version,
    });
  }
  const close = async () => {
    chains.forEach((c) => c.client.destroy());
    await Promise.all(servers.map((s) => s.close()));
    await destroyWorker();
  };
  return { ah: chains[0]!, people: chains[1]!, close };
}

async function sendAs(chain: Chain, signer: string, tx: Transaction<any>) {
  const nonce = await chain.client._request<number, [string]>('system_accountNextIndex', [signer]);
  const extrinsic = bytesToHex(await tx.create(getFakeTxCreator(signer), { nonce, mortality: { mortal: false } }));
  const parent = await head(chain);
  await chain.client._request('dev_newBlock', [{ transactions: [extrinsic] }]);
  return (await eventsSince(chain, parent)).filter((e) => e.block === parent + 1);
}

const fund = (chain: Chain, who: string, free: bigint) =>
  chain.client._request('dev_setStorage', [
    { System: { Account: [[[who], { providers: 1, data: { free: free.toString() } }]] } },
  ]);

const encoded = async (tx: Transaction<any>): Promise<Uint8Array> => {
  const data: any = await tx.getEncodedData();
  return data instanceof Uint8Array ? data : data.asBytes();
};

const here = { parents: 1, interior: { type: 'Here' } };
const pasAsset = (amount: bigint) => ({ id: here, fun: { type: 'Fungible', value: amount } });
const localAccount = (id: Hex) => ({
  parents: 0,
  interior: { type: 'X1', value: { type: 'AccountId32', value: { network: undefined, id } } },
});

function grantProgram(ah: Chain, peopleId: number, contractId: Hex, proxiedCall: Uint8Array, fee: bigint) {
  return xcmCodec(ah).enc({
    type: 'V5',
    value: [
      { type: 'WithdrawAsset', value: [pasAsset(fee)] },
      { type: 'SetFeesMode', value: { jit_withdraw: true } },
      {
        type: 'InitiateTransfer',
        value: {
          destination: { parents: 1, interior: { type: 'X1', value: { type: 'Parachain', value: peopleId } } },
          remote_fees: { type: 'Teleport', value: { type: 'Definite', value: [pasAsset(fee)] } },
          preserve_origin: true,
          assets: [],
          remote_xcm: [
            { type: 'AliasOrigin', value: localAccount(contractId) },
            {
              type: 'Transact',
              value: { origin_kind: { type: 'SovereignAccount' }, fallback_max_weight: undefined, call: proxiedCall },
            },
            { type: 'ExpectTransactStatus', value: { type: 'Success' } },
            { type: 'RefundSurplus' },
            {
              type: 'DepositAsset',
              value: {
                assets: { type: 'Wild', value: { type: 'AllCounted', value: 1 } },
                beneficiary: localAccount(contractId),
              },
            },
          ],
        },
      },
    ],
  });
}

const summarize = (events: ChainEvent[]) =>
  events
    .filter((e) => e.pallet !== 'ParachainSystem')
    .map((e) => `#${e.block} ${e.pallet}.${e.name} ${json(e.value).slice(0, 400)}`)
    .join('\n');

const has = (events: ChainEvent[], pallet: string, name: string) =>
  events.some((e) => e.pallet === pallet && e.name === name);

const { ah, people, close } = await startPair();
try {
  console.log(`AH ${ah.specName} ${ah.specVersion} para ${ah.paraId} at #${ah.forkedAt}`);
  console.log(`People ${people.specName} ${people.specVersion} para ${people.paraId} at #${people.forkedAt}`);

  await fund(ah, ALICE, 1_000_000n * PAS);
  await ah.client._request('dev_newBlock', [{ count: 1 }]);
  await submit(ah, ah.api.tx.Revive.map_account());

  const forwarder = loadArtifact(
    fileURLToPath(new URL('../contracts/out/XcmForwarder.sol/XcmForwarder.json', import.meta.url)),
  );
  const { address } = await deploy(ah, forwarder);
  const contractSs58 = contractAccount(address);
  const contractId = `${address}${'ee'.repeat(12)}` as Hex;
  console.log(`forwarder ${address} = ${contractSs58}`);
  await transferPas(ah, contractSs58, 100n * PAS);

  const sudoKey: string = await query(people, 'Sudo', 'Key');
  console.log(`People sudo key ${sudoKey}`);
  await fund(people, sudoKey, 1_000_000n * PAS);
  await people.client._request('dev_newBlock', [{ count: 1 }]);

  const claimant = ss58(bytesToHex(randomBytes(32)));
  const attester = ss58(`0x64696d32666374${'00'.repeat(25)}`);
  const grant = people.api.tx.NftCredits.testnet_grant_nft_claim_credit({
    claimant: { type: 'Account', value: claimant },
    attester: { type: 'Account', value: attester },
    game_index: FAUCET_GAME_BASE,
    round: 0,
    attester_position: 0,
  });
  const sudo = people.api.tx.Sudo.sudo({ call: grant.decodedCall });
  const proxied = await encoded(
    people.api.tx.Proxy.proxy({
      real: { type: 'Id', value: sudoKey },
      force_proxy_type: undefined,
      call: sudo.decodedCall,
    }),
  );
  const mask = (): Promise<bigint> =>
    query(people, 'NftCredits', 'AwardedNftClaimCredits', FAUCET_GAME_BASE, { type: 'Account', value: claimant });

  const attempt = async (label: string, fee: bigint) => {
    const program = grantProgram(ah, people.paraId, contractId, proxied, fee);
    const peopleFrom = await head(people);
    const result = await call(ah, address, forwarder.abi, 'run', [bytesToHex(program)]);
    assert.ok(has(result.events, 'PolkadotXcm', 'Sent'), `${label}: no message left Asset Hub`);
    const events = await untilEvent(people, peopleFrom, (e) => e.pallet === 'MessageQueue', 5);
    console.log(`\n== ${label}\n${summarize(events)}`);
    return events;
  };

  const refused = await attempt('without proxy', 1n * PAS);
  assert.ok(!has(refused, 'NftCredits', 'NftClaimCreditAwarded'), 'a credit was awarded without the proxy');
  assert.equal(await mask(), 0n);

  const added = await sendAs(
    people,
    sudoKey,
    people.api.tx.Proxy.add_proxy({
      delegate: { type: 'Id', value: contractSs58 },
      proxy_type: { type: 'Any' },
      delay: 0,
    }),
  );
  assert.ok(has(added, 'Proxy', 'ProxyAdded'), 'add_proxy failed');

  const granted = await attempt('with proxy', 1n * PAS + 1n);
  assert.ok(has(granted, 'Proxy', 'ProxyExecuted'), 'the proxy call did not run');
  assert.ok(has(granted, 'Sudo', 'Sudid'), 'the sudo call did not run');
  assert.ok(has(granted, 'NftCredits', 'NftClaimCreditAwarded'), 'no credit was awarded');
  assert.equal(await mask(), 1n);
  console.log('\nNFT CREDITS SPIKE OK');
} finally {
  await close();
}
