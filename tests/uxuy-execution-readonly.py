"""Compare fresh UXUY gateway responses with separately labelled public BSC replay evidence.

Usage: python3 tests/uxuy-execution-readonly.py --wallets ADDRESS1 ADDRESS2 --output path.json
Set UXUY_BSC_RPC_URL to a BSC read node. UXUY_TRACE_RPC_URL optionally selects a trace/archive node.
Set UXUY_TEST_BACKEND_URL to use a backend other than the local preview API.
Optional --gateway-helper points to a different authenticated quote(req) implementation.
All EVM RPCs are reads. Historical calls reuse only public calldata/from/value, never raw transactions.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uxuy_quote_evidence import ROUTER, gateway_error, select_quote
from uxuy_readonly_gateway import new_order_id

CHAIN = os.getenv('UXUY_BSC_RPC_URL')
TRACE = os.getenv('UXUY_TRACE_RPC_URL') or CHAIN
MARKET = os.getenv('UXUY_TEST_BACKEND_URL', 'http://127.0.0.1:3291').rstrip('/') + '/api/v1/platforms/bsc'
ZERO = '0x' + '00' * 20
MULTICALL = '0xca11bde05977b3631167028862be2a173976ca11'
VERIFIED = ROUTER
TOPIC = '0xfad3e93c5edf363a6a7db9e8df2679b14559c44e44a66a163359056050ab806f'
# ERC20 pair-level Swap log signatures (V2, Uniswap V3, Pancake V3).
POOL_SWAP_EVENTS={
    '0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822',
    '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67',
    '0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83',
}
CAKE = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82'
ASSETS = [('outer-CAKE', CAKE), ('four', '0xbafbe22b94c908702471532fbad524b21126ffff'),
          ('flap', '0xb552becd52f3467384159f3070449d80103f8888'),
          ('genius', '0x970a662fb7edb8796ca4405edbabd8ae16186666')]
# Successful published transactions found by filtering this deployment's Traded logs.
HASHES = [
    '0xb71f8c0cd015d811ad0529830e32d72389368647f5a9b95a4ac332c0cd7d4a2a',
    '0x59e5c77951744a438daa7a184dae8d86e187b1aa2c1449d8581da4e4967d2539',
    '0x9b75b318a9b1c7db84bf1e77f96306386c379fb2595132dd4f7b460ea88b1d12',
    '0x19e1874a808d40af1512eecc6be68cd14343545c74313374118f6d1bcf18e425',
    '0xe14fbc0bda5012467c21f6a17ba06daf004f829d4331644278bb139a7b9c60c6',
    '0x2852c892685ff4d96d291548325c3aeff09b05d5e2795c5055a0d63230274146',
]
FIXED_PAIR_BLOCK = 134510217
READ_METHODS = {'eth_chainId', 'eth_blockNumber', 'eth_getTransactionByHash', 'eth_getTransactionReceipt',
                'eth_getCode', 'eth_call', 'eth_getBlockByNumber', 'eth_simulateV1', 'debug_traceTransaction'}


def utc():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def post(url, data):
    req = Request(url, data=json.dumps(data).encode(), headers={
        'Content-Type': 'application/json', 'User-Agent': 'UXUY-release-readonly/1'})
    with urlopen(req, timeout=22) as response:
        return json.load(response)


def rpc(method, params, url=CHAIN):
    if method not in READ_METHODS:
        raise ValueError('unsupported read-only method')
    response = post(url, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    if 'error' in response:
        err = response['error']
        raise RuntimeError(f'{method} [{err.get("code")}] {str(err.get("message", ""))[:180]}')
    return response['result']


def calldata_hash(data):
    return hashlib.sha256(bytes.fromhex(data.removeprefix('0x'))).hexdigest()


def word(a):
    return a.removeprefix('0x').rjust(64,'0') if isinstance(a,str) else f'{a:064x}'


def addr(n):
    return f'0x{n:040x}'


def low(x):
    return '0x'+x[-40:].lower()


def txcall(wallet, target, data, value=0):
    return {'from':wallet, 'to':target, 'data':data, 'value':hex(value), 'gasPrice':'0x0'}


def balance(asset, who):
    return txcall(ZERO, MULTICALL if asset==ZERO else asset,
                  ('0x4d2301cc' if asset==ZERO else '0x70a08231')+word(who))


def approval(asset, owner, target, amount):
    return txcall(owner, asset,'0x095ea7b3'+word(target)+word(amount))


def allowance(asset, owner, target):
    return txcall(ZERO,asset,'0xdd62ed3e'+word(owner)+word(target))


def simulate(calls, block, at_time=None):
    override = {'baseFeePerGas':'0x0'}
    if at_time is not None:
        override['time'] = at_time
    opts = {'blockStateCalls':[{'blockOverrides':override,'calls':calls}],'validation':False}
    try:
        block_result = rpc('eth_simulateV1',[opts,block],TRACE)[0]
    except (HTTPError,RuntimeError) as primary:
        if TRACE == CHAIN:
            raise
        try:
            block_result = rpc('eth_simulateV1',[opts,block],CHAIN)[0]
        except (HTTPError,RuntimeError) as secondary:
            raise RuntimeError(f'eth_simulateV1 trace RPC: {safe_error(primary)}; base RPC: {safe_error(secondary)}') from None
    return block_result


def traded(logs, contract=VERIFIED):
    rows=[]
    for row in logs:
        topics=row.get('topics',[])
        if row.get('address','').lower()!=contract or not topics or topics[0]!=TOPIC:
            continue
        words=[int(row['data'][i:i+64],16) for i in range(2,len(row['data']),64)]
        if len(words)!=11 or len(topics)!=4:
            raise RuntimeError('unexpected Traded event ABI')
        rows.append({'orderId':str(words[0]),'sender':low(topics[1]),'receiver':low(topics[2]),'shareRecipient':low(topics[3]),
                     'tokenIn':addr(words[1]),'in':str(words[2]),'tokenOut':addr(words[4]),
                     'out':str(words[5]),'bridgeTxnId':str(words[6]),'feeAsset':addr(words[7]),
                     'fee':str(words[8]),'feeShare':str(words[9]),'extraFee':str(words[10])})
    return rows


def frames(root):
    yield root
    for child in root.get('calls',[]):
        yield from frames(child)


def replay_case(txhash):
    tx=rpc('eth_getTransactionByHash',[txhash]); receipt=rpc('eth_getTransactionReceipt',[txhash])
    event, = traded(receipt['logs'])
    trace=rpc('debug_traceTransaction',[txhash,{'tracer':'callTracer'}],TRACE)
    target, = [x for x in frames(trace) if x.get('to','').lower()==VERIFIED and x.get('input','')[:10]=='0x5103aafa']
    pulled=[x for x in frames(target) if x.get('to','').lower()==event['tokenIn']
            and x.get('from','').lower()==VERIFIED and x.get('input','')[:10]=='0x23b872dd' and x.get('type')=='CALL']
    txblock=int(tx['blockNumber'],16); block=rpc('eth_getBlockByNumber',[tx['blockNumber'],False])
    parent=rpc('eth_getBlockByNumber',[hex(txblock-1),False])
    # Consecutive subsecond BSC blocks may have identical integer timestamps. The simulation
    # API requires the next virtual block to be at least one second later.
    sim_time=hex(max(int(parent['timestamp'],16)+1,int(block['timestamp'],16)))
    swap=txcall(target['from'].lower(),VERIFIED,target['input'],int(target.get('value','0x0'),16))
    result={'hash':txhash,'block':txblock,'blockHash':receipt['blockHash'],'timestamp':block['timestamp'],
            'outerFrom':tx['from'],'outerTo':tx['to'],'outerSelector':tx['input'][:10],
            'uxuyCaller':swap['from'],'uxuyTarget':swap['to'],'uxuySelector':swap['data'][:10],
            'uxuyCalldataSha256':calldata_hash(swap['data']),'uxuyValue':str(int(swap['value'],16)),
            'observedInputTransferFromSpender':VERIFIED if pulled else None, 'onchainEvent':event}
    result['parentBlockFullTransactionReplay']=swap_sim(
        txcall(tx['from'],tx['to'],tx['input'],int(tx['value'],16)),event,hex(txblock-1),sim_time)
    if event['tokenIn']!=ZERO:
        result['parentBlockIsolatedRouterReplay']=swap_sim(swap,event,hex(txblock-1),sim_time)
        result['parentBlockSimulatedResetAndExactApprovalBeforeSwap']=swap_sim(swap,event,hex(txblock-1),sim_time,True)
    else:
        result['parentBlockIsolatedRouterReplay']=swap_sim(swap,event,hex(txblock-1),sim_time)
    return result,swap


def prepared(swap, event, exact):
    token_in=event['tokenIn']; who=event['sender']; target=event['receiver']
    probes=[balance(token_in,who),balance(event['tokenOut'],target)]
    labels=['nativeOrTokenInBefore','nativeOrTokenOutBefore']
    if token_in!=ZERO:
        probes.append(allowance(token_in,who,VERIFIED)); labels.append('allowanceBefore')
        if exact:
            probes += [approval(token_in,who,VERIFIED,0),allowance(token_in,who,VERIFIED),
                       approval(token_in,who,VERIFIED,int(event['in'])),allowance(token_in,who,VERIFIED)]
            labels += ['approvalReset','allowanceAfterReset','approveExact','allowanceImmediatelyBeforeSwap']
    probes += [swap,balance(token_in,who),balance(event['tokenOut'],target)]; labels += ['swap','nativeOrTokenInAfter','nativeOrTokenOutAfter']
    if token_in!=ZERO:
        probes.append(allowance(token_in,who,VERIFIED)); labels.append('allowanceAfter')
    return labels,probes


def measure(labels, results, expected, exact):
    if len(labels)!=len(results):
        raise ValueError('simulation returned unexpected number of calls')
    calls=dict(zip(labels,results))
    def val(label):
        data=calls[label].get('returnData','')
        return int(data,16) if len(data)==66 else None
    errors = {label:{"status":c.get('status'),"error":c.get('error')} for label,c in calls.items() if c.get('status')!='0x1'}
    logs=calls['swap'].get('logs',[])
    event_list=traded(logs)
    pools=sorted({r['address'].lower() for r in logs if r.get('topics') and r['topics'][0] in POOL_SWAP_EVENTS})
    before_in=val('nativeOrTokenInBefore'); after_in=val('nativeOrTokenInAfter')
    before_out=val('nativeOrTokenOutBefore'); after_out=val('nativeOrTokenOutAfter')
    spent=before_in-after_in if None not in (before_in,after_in) else None
    received=after_out-before_out if None not in (before_out,after_out) else None
    actual=event_list[0] if len(event_list)==1 else {}
    keys=['orderId','sender','receiver','tokenIn','tokenOut','in']
    out={'simulatedSwapSucceeded':calls['swap'].get('status')=='0x1','errors':errors,'gasUsed':int(calls['swap'].get('gasUsed','0x0'),16),
         'inputBalanceBefore':str(before_in),'inputBalanceAfter':str(after_in),'inputWalletSpent':str(spent),
         'outputBalanceBefore':str(before_out),'outputBalanceAfter':str(after_out),'receiverGained':str(received),'simulatedEvents':event_list,'observedPairSwapEmitters':pools}
    out.update({k:str(val(k)) for k in labels if k.startswith('allowance')})
    out['exactApprovalVerified']= (val('allowanceAfterReset')==0 and val('allowanceImmediatelyBeforeSwap')==int(expected['in'])) if exact else None
    valid_spent = (spent is not None and 0 < spent <= int(expected['in'])) if expected['tokenIn']==ZERO else spent==int(expected['in'])
    out['walletAmountsAndZeroFeeEventVerified']=(
        not errors and len(event_list)==1 and all(actual.get(k)==expected.get(k) for k in keys)
        and all(actual.get(k)=='0' for k in ('fee','feeShare','extraFee','bridgeTxnId'))
        and actual.get('shareRecipient')==ZERO and valid_spent and received==int(actual.get('out','-1'))
        and received is not None and received>=int(expected.get('minOut', '1'))
        and (not exact or out['exactApprovalVerified']))
    return out


def swap_sim(swap,event,block,at_time,exact=False):
    labels,calls=prepared(swap,event,exact)
    sim=simulate(calls,block,at_time)
    return dict(measure(labels,sim['calls'],event,exact),simulationBlock=sim['number'],baseBlock=block)


def joined(case1,case2,block):
    order=[]; calls=[]; batches=[]
    for row, swap in [case1,case2]:
        event=row['onchainEvent']; labels,group=prepared(swap,event,True)
        batches.append((labels,event)); calls+=group; order.append(row['hash'])
    sim=simulate(calls,hex(block)); results=sim['calls']; offset=0; measurements=[]
    for labels,event in batches:
        measurements.append(measure(labels,results[offset:offset+len(labels)],event,event["tokenIn"]!=ZERO));offset+=len(labels)
    return {'historicalCallHashesInSimulatedOrder':order,'baseBlock':block,'simulatedBlock':sim['number'],
            'sameInputToken':batches[0][1]['tokenIn']==batches[1][1]['tokenIn'],
            'sameOutputToken':batches[0][1]['tokenOut']==batches[1][1]['tokenOut'],
            'distinctWallets':batches[0][1]['sender']!=batches[1][1]['sender'],
            'walletOrder':[event['sender'] for _,event in batches],
            'sharedObservablePairPools':sorted(set(measurements[0]['observedPairSwapEmitters']) & set(measurements[1]['observedPairSwapEmitters'])),
            'wallets':measurements}


def two_wallet_native_buy(template, test_wallets):
    # The verified trade ABI stores recipient at word four (including the outer tuple offset).
    # No per-wallet gateway results exist for these orders. Only this recipient word and
    # simulation sender are changed in each control; the same original swap path, amount,
    # deadline and nested bytes are retained, including the historical order-id.
    row,swap=template
    event=row['onchainEvent']; assert event['tokenIn']==ZERO
    start=10+4*64
    assert swap['data'][start:start+64].lower()==word(event['receiver'])
    wallets=[]
    for w in test_wallets:
        data=swap['data'][:start]+word(w)+swap['data'][start+64:]
        rewritten=dict(row,onchainEvent=dict(event,sender=w,receiver=w))
        wallets.append((rewritten,dict(swap,data=data,**{'from':w})))
    base=row['block']-1
    singles=[swap_sim(call,case['onchainEvent'],hex(base),None) for case,call in wallets]
    orders=[joined(wallets[a],wallets[b],base) for a,b in [(0,1),(1,0)]]
    return {'provenance':'Public historical BSC route, sender/recipient varied solely for a read-only experiment; not fresh gateway quotes.',
            'sourceHash':row['hash'],'baseBlock':base,'wallets':test_wallets,'inputAmountPerWallet':event['in'],
            'tokenIn':event['tokenIn'],'tokenOut':event['tokenOut'],'singleWalletBaselines':singles,'bothOrders':orders}


def seeded_allowance(template):
    # Seed only an ERC20 allowance inside simulated block one, then read it before calling
    # the unmodified historical swap inside block two. No persistent approval is created.
    row,swap=template; event=row['onchainEvent']; amount=int(event['in'])
    assert event['tokenIn']!=ZERO
    token=event['tokenIn']; w=event['sender']; labels,group=prepared(swap,event,False)
    seed=[approval(token,w,VERIFIED,0),approval(token,w,VERIFIED,amount),allowance(token,w,VERIFIED)]
    params={'validation':False,'blockStateCalls':[{'blockOverrides':{'baseFeePerGas':'0x0'},'calls':calls} for calls in [seed,group]]}
    base=hex(row['block']-1)
    response=rpc('eth_simulateV1',[params,base],TRACE)
    checks=response[0]['calls']
    seeded=all(v['status']=='0x1' for v in checks) and int(checks[-1]['returnData'],16)==amount
    return {'sourceHash':row['hash'],'baseBlock':base,'provenance':'Allowance explicitly seeded in the preceding simulated block; real balances and swap calldata are unchanged.',
            'allowanceSeededAndVerified':seeded,'wallet':w,'target':VERIFIED,'token':token,'amount':str(amount),
            'trade':measure(labels,response[1]['calls'],event,False)}


def fresh(gateway, test_wallets):
    attempts=[]
    for name,ca in ASSETS:
        market=post(MARKET,{'token':ca})['result']
        for side,approval_mode in [('buy','direct'),('sell','direct'),('sell','exact_approval_required')]:
            w=test_wallets[0]
            if side=='sell' and name!='outer-CAKE':
                w=test_wallets[1]
            order=new_order_id()
            decimals=18 if side=='buy' else market['decimals']
            atoms=10**15 if side=='buy' else 10**decimals//100
            p={'sender':w,'receiver':w,'tokenIn':ZERO if side=='buy' else ca,
               'tokenOut':ca if side=='buy' else ZERO,'amountIn':'0.001' if side=='buy' else '0.01',
               'decimals':decimals,'withTx':approval_mode=='direct','noFee':True,'orderId':order,'slippage':5000,'size':3}
            item={'utc':utc(),'name':name,'asset':ca,'stageFromChainReader':{'platform':market['platform'],'external':market['external'],'block':market.get('block')},
                  'side':side,'mode':approval_mode,'request':p}
            try:
                rows=gateway.quote(p); item['gatewayReturned']=len(rows)
                row,checks=select_quote(rows,p,atoms,ZERO)
                item['routeValidation']=checks
                if row:
                    c=row['calldata']
                    encoded=c.get('data','').removeprefix('0x')
                    item['selectedRoute']={'to':c['to'],'selector':encoded[:8],'value':c['value'],'executed':c['executed'],
                        'quoteOut':str(row['amount']),'minOut':str(row['minAmount']),
                        'calldataSha256':calldata_hash(encoded)}
                    seq=txcall(w,VERIFIED,'0x'+encoded,int(str(c['value']),0))
                    event={'tokenIn':p['tokenIn'],'tokenOut':p['tokenOut'],'sender':w,'receiver':w,
                           'in':str(atoms),'minOut':str(row['minAmount']),'orderId':order}
                    item['simulation']=swap_sim(seq,event,'latest',None,approval_mode=='exact_approval_required')
            except (OSError,RuntimeError,ValueError,KeyError) as exc:
                item['error']=safe_error(exc)
            attempts.append(item)
            time.sleep(0.17)
    return attempts


def safe_error(exc):
    if isinstance(exc,HTTPError):
        return 'HTTP '+str(exc.code)
    msg=str(exc)
    if msg.startswith(('eth_', 'debug_traceTransaction ')):
        return msg[:210]
    return gateway_error(exc)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gateway-helper',type=Path,default=Path(__file__).with_name('uxuy_readonly_gateway.py'))
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--wallets', nargs=2, required=True, metavar=('ADDRESS1','ADDRESS2'),
                        help='two public BSC addresses for simulated balance checks, funded at the replay block')
    args=parser.parse_args()
    if not CHAIN:
        parser.error('set UXUY_BSC_RPC_URL to a BSC read node')
    wallets = [address.lower() for address in args.wallets]
    if any(not re.fullmatch(r'0x[0-9a-f]{40}', address) or address == ZERO for address in wallets) or wallets[0] == wallets[1]:
        parser.error('--wallets requires two different nonzero public BSC addresses')
    spec=importlib.util.spec_from_file_location('audited_quote_gateway',args.gateway_helper)
    gateway=importlib.util.module_from_spec(spec); spec.loader.exec_module(gateway)
    out={'startUtc':utc(),'chainId':int(rpc('eth_chainId',[]),16),
         'noTransactionSignedOrBroadcast':True,'historicalBscDeployment':VERIFIED,'freshAuthenticatedGateway':fresh(gateway, wallets)}
    histories=[]; resolved={}
    with ThreadPoolExecutor(max_workers=2) as workers:
        work={tx:workers.submit(replay_case,tx) for tx in HASHES}
        for tx,job in work.items():
            try:
                row,call=job.result(); histories.append(row);resolved[tx]=(row,call)
            except (OSError,RuntimeError,ValueError,KeyError) as exc:
                histories.append({'hash':tx,'error':safe_error(exc)})
    out['publicHistoricalReplays']=histories
    for a,b in [(2,3)]:
        if HASHES[a] in resolved and HASHES[b] in resolved:
            try:
                out['nativeSellOrderSimulations']=[joined(resolved[HASHES[i]],resolved[HASHES[j]],FIXED_PAIR_BLOCK) for i,j in [(a,b),(b,a)]]
            except (OSError,RuntimeError,ValueError,KeyError) as exc:
                out['nativeSellOrderSimulationsError']=safe_error(exc)
    for name,index,f,extra in [('twoWalletNativeBuyControl',0,two_wallet_native_buy,(wallets,)),('previousBlockAllowanceControl',1,seeded_allowance,())]:
        if HASHES[index] in resolved:
            try:
                out[name]=f(resolved[HASHES[index]], *extra)
            except (OSError,RuntimeError,ValueError,KeyError) as exc:
                out[name]={'error':safe_error(exc)}
    isolated=[r.get('parentBlockSimulatedResetAndExactApprovalBeforeSwap',r.get('parentBlockIsolatedRouterReplay',{})) for r in histories]
    attempts=out['freshAuthenticatedGateway']
    out['summary']={'freshGatewayRequests':len(attempts),'freshGatewayHttp401':sum(r.get('error')=='UXUY HTTP 401' for r in attempts),
                    'freshGatewayRoutesReturned':sum(r.get('gatewayReturned',0) for r in attempts),
                    'freshOrdersWithVerifiedCalldata':sum(bool(r.get('routeValidation',{}).get('orderIdMatches')) for r in attempts),
                    'freshOrdersWithBalanceMinimumAndZeroFeesVerified':sum(r.get('simulation',{}).get('walletAmountsAndZeroFeeEventVerified') is True for r in attempts),
                    'historicalRouterCallsBalanceAndZeroFeesVerified':sum(r.get('walletAmountsAndZeroFeeEventVerified') is True for r in isolated),
                    'historicalWholeTransactionStatusSuccess':sum(r.get('parentBlockFullTransactionReplay',{}).get('simulatedSwapSucceeded') is True for r in histories),
                    'historicalWholeTransactionWalletMatchesInnerTrade':sum(r.get('parentBlockFullTransactionReplay',{}).get('walletAmountsAndZeroFeeEventVerified') is True for r in histories)}
    out['finishUtc']=utc()
    args.output.parent.mkdir(exist_ok=True,parents=True)
    temporary=args.output.with_suffix('.tmp')
    temporary.write_text(json.dumps(out,indent=2,ensure_ascii=False)+'\n')
    temporary.replace(args.output)


if __name__=='__main__':
    main()
