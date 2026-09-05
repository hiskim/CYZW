# Bridge Contract

All bridge messages use an object with `event` and `payload` fields. Payload fields are JSON scalars only. The native host validates authorization and state before taking an action; a bridge message never directly changes the EngineHost lifecycle.

## H5 to Swift

H5 messages use `window.webkit.messageHandlers.engineHost.postMessage(...)`. This channel is available only to `WebKitInstance`; Cocos does not use it.

| Event | Payload | When it is sent | Swift result |
| --- | --- | --- | --- |
| `ready` | `{ pageName: string }` | The DOM is ready. | Resolves `WebKitInstance.start` and emits `.ready`. |
| `purchase` | `{ itemID: string }` | A store action is pressed. | Emits `.bridgeMessage`; L1 validates purchase authority. |
| `inventoryTabChanged` | `{ tab: string }` | The inventory category changes. | Emits `.bridgeMessage`. |
| `useItem` | `{ itemID: string }` | The player invokes an inventory item. | Emits `.bridgeMessage`; game service validates it. |
| `eventSelected` | `{ eventID: string }` | The player selects an activity. | Emits `.bridgeMessage`. |
| `settingChanged` | `{ key: string, value: boolean }` | A game setting toggles. | Emits `.bridgeMessage`; L1 persists only approved values. |
| `paused` / `resumed` | `{}` | Optional H5 acknowledgement. | Emits the matching lifecycle event. |
| `error` | `{ message: string }` | H5 cannot continue. | Emits `.errorOccurred` and marks the host failed. |

## Cocos to Swift

The Objective-C++ adapter calls `CocosBridge.receiveJSBEvent(_:payloadJSON:)` on the main thread. This is the only Cocos JSB-to-Swift event path.

| Event | Payload | When it is sent | Swift result |
| --- | --- | --- | --- |
| `ready` | `{ sceneName: string }` | Director finishes loading the requested scene. | Emits `.ready`. |
| `paused` / `resumed` | `{}` | Director acknowledges an L1 lifecycle request. | Updates state and emits the matching event. |
| `sceneChanged` | `{ sceneName: string }` | A scene transition completes. | Emits `.bridgeMessage`. |
| `resourceInjected` | `{ resource: string }` | JSB accepts an injected resource. | Emits `.bridgeMessage`; L1 owns the injection request. |
| `performanceWarning` | `{ message: string, memoryMB: number }` | Cocos detects a frame or memory budget breach. | Emits `.bridgeMessage`; L1 may pause or close the instance. |
| `error` | `{ message: string }` | Scene, renderer, or JSB execution fails. | Emits `.errorOccurred` and marks the host failed. |

## Swift to Cocos

`CocosBridge` calls the Cocos adapter directly for lifecycle operations. `inject(resource:)` serializes one of the following payloads and evaluates `globalThis.EngineHostBridge.injectResource(payload)` in the active JSB realm:

```json
{ "kind": "local|remote|bundled", "value": "string" }
```

Only the active single Cocos instance can receive this call. Plugins request injection through `PluginSandbox`; L1 performs the actual `EngineHost.inject(resource:)` call after approval.
