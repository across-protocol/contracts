## Flows

### Flow 1: Direct OFT/CCTP (sufficient funds, no relayer top-up needed)

```
1. User signs: (order, requirements[], submitter, salt)
2. Submitter calls OrderGateway.submitOrder() with:
   - User's signed data (order, requirements, salt, signature)
   - Submitter's data (tokenInput, dataInputs[])
3. OrderGateway: verifies signature, pulls tokens from user + submitter, generates orderId
4. OrderGateway calls MetaReqHandler.validateAndSubmit()
5. MetaReqHandler: matches dataInputs to requirements by handler, validates all, calls IBridgeProtocol.deposit()
6. Bridge (OFT/CCTP): transfers tokens cross-chain
7. DST: Bridge-specific receiver calls IntentStore.receiveIntent()
   - CCTP: Finalizer calls receiveMessage() → tokens minted → receiveIntent()
   - OFT: lzCompose() called → receiveIntent()
8. IntentStore: amount >= outputAmount → immediately executes via IntentHandler
9. IntentHandler executes user's message
```

### Flow 2: Sponsored Fill (relayer tops up insufficient funds)

```
1-6. Same as Flow 1
7. DST: Bridge receiver calls IntentStore.receiveIntent()
8. IntentStore: amount < outputAmount → stores intent (executed = false)
9. Relayer discovers stored intent via events or API
10. Relayer calls IntentStore.fillIntent() with additional tokens
11. IntentStore transfers (bridged + relayer) tokens to IntentHandler
12. IntentHandler executes user's message
13. Protocol repays relayer via Across bundles + reward
```

### Flow 3: Multi-Hop (A -> B -> C)

```
1-6. Order goes A -> B (any flow above)
7. IntentHandler on B receives tokens + message containing nextHop Order
8. IntentHandler calls local OrderGateway.submitOrder(nextHop)
9. New order goes B -> C
10. IntentHandler on C executes final action
```

### Flow 4: Traditional SpokePool

```
1. User calls OrderGateway.submitOrder(bridgeProtocol=SpokePool)
2. OrderGateway -> MetaReqHandler -> ISpokePoolBridge.deposit()
3. ISpokePoolBridge calls SpokePool.depositV3()
4. Relayer fills via SpokePool.fillRelay() on destination
5. SpokePool calls IntentHandler.handleV3AcrossMessage()
```
