import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { type Hex, bytesToHex, hexToBytes, parseAbi } from 'viem';
import {
  ALICE,
  type Chain,
  type ChainEvent,
  accountHex,
  call,
  contractAccount,
  head,
  instantiate,
  json,
  newBlock,
  query,
  read,
  ss58,
  startNetwork,
  submit,
  transferPas,
  trappedAssets,
  untilEvent,
  xcmCodec,
} from './lib.ts';

const PAS = 10n ** 10n;
const FAUCET_GAME_BASE = 0x8000_0000;
const FAUCET_ATTESTER = ss58(bytesToHex(new TextEncoder().encode('dim2fct'.padEnd(32, '\0'))));
const grantAbi = parseAbi(['function grant(bytes32 claimant)', 'function program(bytes32 claimant) view returns (bytes)']);
const grantBlob = readFileSync(new URL('../pvm/nft-credit-grant/nft-credit-grant.polkavm', import.meta.url));

interface Slot {
  gameIndex: number;
  round: number;
  attesterPosition: number;
}

const fund = (chain: Chain, who: string, free: bigint) =>
  chain.client._request('dev_setStorage', [
    { System: { Account: [[[who], { providers: 1, data: { free: free.toString() } }]] } },
  ]);

const here = { parents: 1, interior: { type: 'Here' } };
const pasAsset = (amount: bigint) => ({ id: here, fun: { type: 'Fungible', value: amount } });
const localAccount = (id: Hex) => ({
  parents: 0,
  interior: { type: 'X1', value: { type: 'AccountId32', value: { network: undefined, id } } },
});

async function proxiedGrant(people: Chain, sudoKey: string, claimant: string, slot: Slot): Promise<Uint8Array> {
  const grant = people.api.tx.NftCredits.testnet_grant_nft_claim_credit({
    claimant: { type: 'Account', value: claimant },
    attester: { type: 'Account', value: FAUCET_ATTESTER },
    game_index: slot.gameIndex,
    round: slot.round,
    attester_position: slot.attesterPosition,
  });
  const sudo = people.api.tx.Sudo.sudo({ call: grant.decodedCall });
  return people.api.tx.Proxy.proxy({
    real: { type: 'Id', value: sudoKey },
    force_proxy_type: undefined,
    call: sudo.decodedCall,
  }).getEncodedData();
}

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

const net = await startNetwork(['assetHubNext', 'peopleNext']);
try {
  const { assetHubNext: ah, peopleNext: people } = net.chains;
  console.log(`AH ${ah.specName} ${ah.specVersion} para ${ah.paraId} at #${ah.forkedAt}`);
  console.log(`People ${people.specName} ${people.specVersion} para ${people.paraId} at #${people.forkedAt}`);

  const sudoKey: string = await query(people, 'Sudo', 'Key');
  console.log(`People sudo key ${sudoKey}`);
  await fund(people, sudoKey, 1_000_000n * PAS);
  await newBlock(people);
  await fund(ah, ALICE, 1_000_000n * PAS);
  await newBlock(ah);

  const { address } = await instantiate(ah, grantBlob, hexToBytes(accountHex(sudoKey)));
  const contractSs58 = contractAccount(address);
  const contractId = accountHex(contractSs58);
  console.log(`granter ${address} = ${contractSs58}`);
  await transferPas(ah, contractSs58, 100n * PAS);

  const claimant = ss58(bytesToHex(randomBytes(32)));
  const claimantId = accountHex(claimant);
  const mask = (): Promise<bigint> =>
    query(people, 'NftCredits', 'AwardedNftClaimCredits', FAUCET_GAME_BASE, { type: 'Account', value: claimant });
  const fromAssetHub = (e: ChainEvent) =>
    e.pallet === 'MessageQueue' && e.value?.origin?.type === 'Sibling' && e.value.origin.value === ah.paraId;

  const attempt = async (label: string, slot: Slot) => {
    const built = await read(ah, address, grantAbi, 'program', [claimantId]);
    const proxied = await proxiedGrant(people, sudoKey, claimant, slot);
    const expected = grantProgram(ah, people.paraId, contractId, proxied, PAS);
    assert.equal(built, bytesToHex(expected), `${label}: the contract built another program`);

    const peopleFrom = await head(people);
    const result = await call(ah, address, grantAbi, 'grant', [claimantId]);
    assert.ok(has(result.events, 'PolkadotXcm', 'Sent'), `${label}: no message left Asset Hub`);
    const events = await untilEvent(people, peopleFrom, fromAssetHub, 5);
    console.log(`\n== ${label}\n${summarize(events)}`);
    return events;
  };

  const refused = await attempt('without proxy', { gameIndex: FAUCET_GAME_BASE, round: 0, attesterPosition: 0 });
  assert.ok(!has(refused, 'NftCredits', 'NftClaimCreditAwarded'), 'a credit was awarded without the proxy');
  assert.equal(await mask(), 0n);
  const refusal = refused.find((e) => e.pallet === 'PolkadotXcm' && e.name === 'ProcessXcmError');
  assert.equal(refusal?.value.error.type, 'ExpectationFalse');
  assert.equal(trappedAssets(refused).length, 1);

  const added = await submit(
    people,
    people.api.tx.Proxy.add_proxy({
      delegate: { type: 'Id', value: contractSs58 },
      proxy_type: { type: 'Any' },
      delay: 0,
    }),
    sudoKey,
  );
  assert.ok(has(added, 'Proxy', 'ProxyAdded'), 'add_proxy failed');

  const granted = await attempt('with proxy', { gameIndex: FAUCET_GAME_BASE, round: 0, attesterPosition: 1 });
  assert.ok(has(granted, 'Proxy', 'ProxyExecuted'), 'the proxy call did not run');
  assert.ok(has(granted, 'Sudo', 'Sudid'), 'the sudo call did not run');
  assert.ok(has(granted, 'NftCredits', 'NftClaimCreditAwarded'), 'no credit was awarded');
  assert.equal(await mask(), 0b10n);
  console.log('\nNFT CREDITS SPIKE OK');
} finally {
  await net.close();
}
