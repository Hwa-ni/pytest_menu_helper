# 알림용 앱 번들 빌드 방식 (2.5단계 샘플)

상태: **확인 완료.** 첫 실행은 알림 권한이 `denied`로 나왔고, 사용자가 시스템 설정 > 알림에서 허용한 뒤 다시 실행하자 `granted=true`, `add result=success`가 나왔으며 알림이 화면에 표시된 것을 사용자가 확인했다(2026-11-17, ad-hoc 서명).

## 결정

→ **Bundle ID**: `dev.yohwan.pytest-menu-helper.sample` (샘플용). 실제 앱은 `dev.yohwan.pytest-menu-helper`를 쓴다.

→ **서명**: 개발자 인증서가 없어(`security find-identity`: 0 valid identities) **ad-hoc(`codesign --sign -`)까지만** 시험했다. Developer ID 서명과 공증은 시험하지 못했다.

→ **빌드 도구**: Xcode 프로젝트 없이 `swiftc` + 셸 스크립트. 산출물은 `~/.pmh-build/`에만 만든다.

## 빌드·실행

```sh
cd spikes/notification-sample
./build.sh adhoc          # ~/.pmh-build/PMHNotificationSample-adhoc.app
./build.sh none           # 서명 없음 비교용
open -W -o ~/.pmh-build/out.txt --stdout ~/.pmh-build/out.txt --stderr ~/.pmh-build/out.txt \
  ~/.pmh-build/PMHNotificationSample-adhoc.app
cat ~/.pmh-build/out.txt
```

`open`으로 실행해야 한다(LaunchServices 경유). 소스는 `main.swift`, 번들 설정은 `Info.plist`(`LSUIElement`로 Dock·메뉴 막대 아이콘 없음).

## 실행 방식별 결과 (macOS 27.2.1, Swift 6.4.2, arm64)

| 방식 | 결과 |
|---|---|
| 번들 없이 실행(`swiftc`로 만든 단독 바이너리, `swift run`도 같은 원리) | 즉시 크래시, 종료 코드 134. `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil` (`UNUserNotificationCenter.current()` 호출 시). 번들 ID가 없어 알림 센터가 앱을 식별하지 못한다 |
| .app 번들, 서명 없음 | 실행 자체가 안 됨. 직접 실행은 SIGKILL(종료 코드 137), `open`은 `Launch failed` / `Launchd job spawn failed`(163). arm64에서는 서명 없는 코드가 실행되지 않는다 |
| .app 번들, ad-hoc 서명, 바이너리를 직접 실행 | 번들 ID는 인식하지만 `Notifications are not allowed for this application`(UNErrorDomain 1), 상태 `notDetermined`. 직접 실행은 정식 앱 실행이 아니라 권한 요청이 처리되지 않음 |
| .app 번들, ad-hoc 서명, `open`으로 실행 | 정상 실행. 권한 요청 결과 `granted=false`, `authorizationStatus=denied`, 같은 오류. `add()`는 호출되지 않음 |

## 확인된 출력 (ad-hoc, `open` 실행)

```
bundleIdentifier=dev.yohwan.pytest-menu-helper.sample
requestAuthorization granted=false error=... "Notifications are not allowed for this application"
authorizationStatus=denied
```

## 알려진 제한

→ **현재까지 확정된 최소 조건**: Bundle ID가 있는 .app 번들 + 서명(ad-hoc 이상) + `open`으로 실행. 이 조건에서 앱이 알림 센터에 등록되고 권한 상태가 `denied`까지 나왔다. 알림 표시 자체는 이 세션에서 확인하지 못했다.

→ **권한 팝업이 보이지 않았다.** 첫 `open` 실행에서 곧바로 `denied`가 나왔다. 팝업이 자동으로 닫혔거나 이 터미널 세션에서 보이지 않았을 수 있다. 원인은 확인하지 못했다.

→ **사용자 확인 필요**: 시스템 설정 > 알림에서 "pytest Menu Helper Sample"이 있는지, 허용으로 바꾼 뒤 샘플을 다시 실행하면 알림이 표시되는지 확인해야 한다. 허용 후에도 `add result=success`가 나오는지 같이 본다. 시스템 설정은 이 작업에서 바꾸지 않았다.

→ ad-hoc 서명은 빌드할 때마다 코드 서명 정보가 바뀌므로 macOS가 앱을 다른 앱으로 볼 수 있다. 안정적인 알림 권한 유지는 Developer ID 서명에서 확인해야 한다(미시험).

→ 배포(다른 Mac)에는 Developer ID 서명과 공증이 필요하다(미시험).
