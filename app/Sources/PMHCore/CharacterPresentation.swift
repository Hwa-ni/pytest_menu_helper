// CharacterPresentation.swift
// 7단계 캐릭터(여우)가 지금 어떤 동작을 할지 정하는 순수 코드와, 캐릭터 창의 위치 규칙, 캐릭터 HTML 페이지 만들기.
// AppKit·WebKit을 쓰지 않는다. 창을 띄우고 애니메이션을 재생하는 일은 PMHApp(CharacterWindow.swift)이 한다.
// 입력: 등록 정보(Registry), 앱 실행과 터미널 실행을 합친 실행 상태(RunSnapshot.merged의 결과).
// 출력: CharacterState(포즈, 작은 상태 글씨, 따르는 환경, 애니메이션을 새로 시작할지 가리는 key, 도움말 문장).
// 설계 결정(사용자 결정 2026-11-17, docs/CHARACTER.md):
// - 여러 환경이 동시에 상태를 가지면, 실행 중인 것이 하나라도 있을 때 달리기(가장 나중에 시작한 실행 기준),
//   없으면 등록한 모든 환경 중 가장 나중에 끝난 결과를 따른다.
// - 성공만 점프(success). 실패(verdict failed)와 수집 오류만 넘어진 포즈(failure).
//   테스트 없음·중단·미완료·skip/xfail 확인 필요·집계/실행 오류는 갸웃하는 포즈(attention)와 상태 글씨로 구분한다.
//   성공 포즈를 쓰는 조건은 집계기 verdict가 "passed"인 경우 하나뿐이다.
// - 결과 포즈는 다음 실행까지 유지한다(성공 점프도 계속 반복).
// - 모든 포즈에서 캐릭터 아래에 상태 글씨를 보인다(사용자 요청 2026-11-17). 글씨는 팝오버 환경 행 문구와 같다
//   (ResultPresentation.activeStatusText·externalStatusText·resultStatusText를 그대로 쓴다). 대기는 "실행 전".
//   진행 글씨("실행 중 2/5")가 바뀌어도 key는 그대로라 달리기 애니메이션은 처음부터 다시 시작하지 않는다.
// 판정 자체는 Python 집계기가 정한 값을 그대로 옮긴다. 여기서는 "어떤 포즈로 보여 줄지"만 정한다.

import Foundation
// CGRect의 minX·intersection 같은 계산 함수는 CoreGraphics에 있다. Foundation만으로는 타입 이름만 보인다.
import CoreGraphics

/// 캐릭터 포즈. rawValue는 HTML 페이지의 템플릿 id(pose-<rawValue>)와 같다.
public enum CharacterPose: String, CaseIterable, Equatable {
    /// 아직 실행이 없음. 정지한 기본 여우(mascot-fox.svg).
    case idle
    /// 실행 중. 제자리 달리기(mascot-fox-animated.svg, 반복).
    case running
    /// 전체 성공. 팔을 든 점프와 반짝임(mascot-fox-success.svg, 반복).
    case success
    /// 실패·수집 오류. 얼굴을 바닥에 댄 옆모습(mascot-fox-error.svg, 한 번 넘어진 뒤 누운 채).
    case failure
    /// 성공도 실패도 아닌 별도 상태. 갸웃하는 여우(mascot-fox-attention.svg, 한 번 기울인 뒤 그대로).
    case attention

    /// 이 포즈에 쓰는 에셋 파일 이름(확장자 제외). 빌드 스크립트가 같은 이름으로 앱 번들에 복사한다.
    public var assetName: String {
        switch self {
        case .idle: return "mascot-fox"
        case .running: return "mascot-fox-animated"
        case .success: return "mascot-fox-success"
        case .failure: return "mascot-fox-error"
        case .attention: return "mascot-fox-attention"
        }
    }
}

/// 캐릭터 창이 보여 줄 값 하나.
public struct CharacterState: Equatable {
    public var pose: CharacterPose
    /// 캐릭터 아래 작은 상태 글씨. 팝오버 환경 행 문구와 같다(예: "실행 전", "터미널 실행 중 2/5", "통과", "실패 1").
    /// 모든 포즈에 있다. 별도 상태(갸웃)는 이 글씨로 어떤 상태인지 구분한다.
    public var label: String
    /// 따르는 환경 id. 클릭으로 팝오버를 열 때 이 환경을 선택해 보여 준다. 대기(idle)면 nil.
    public var envID: String?
    /// 애니메이션을 처음부터 다시 시작할지 가리는 값. 같은 key면 페이지는 그리던 것을 그대로 둔다.
    /// 실행마다(run id), 결과마다(환경 id + 끝난 시각) 달라진다. 빠뜨리면 상태 알림이 올 때마다
    /// 넘어지는 동작이 처음부터 다시 재생되거나, 반대로 새 결과에서 다시 재생되지 않는다.
    public var key: String
    /// 마우스를 올리면 보이는 도움말. 예: "pmh-3.13 · 실패 1 · 터미널".
    public var help: String

    public init(pose: CharacterPose, label: String, envID: String? = nil, key: String, help: String) {
        self.pose = pose; self.label = label; self.envID = envID; self.key = key; self.help = help
    }

    /// 실행도 결과도 없을 때의 값.
    /// 글씨 "실행 전"은 행 문구(아직 실행하지 않은 환경)와 같다.
    public static let idle = CharacterState(pose: .idle, label: "실행 전", key: "idle",
                                            help: "pytest Menu Helper · 아직 실행한 테스트가 없습니다")
}

public enum CharacterPresentation {
    /// 끝난 실행의 포즈.
    /// - Parameter outcome: 앱 실행이나 터미널 실행의 마지막 결과.
    /// - Returns: 포즈. 글씨는 여기서 정하지 않는다(행 문구 함수 ResultPresentation.resultStatusText가 정한다).
    /// 성공 포즈는 집계기 verdict가 "passed"일 때만 쓴다. 종료 코드 0이라도 skip만 있거나 테스트가 없으면
    /// 집계기가 passed를 주지 않으므로 성공 동작이 나오지 않는다(2단계 판정 규칙을 그대로 따른다).
    public static func pose(for outcome: RunOutcome) -> CharacterPose {
        switch outcome {
        case .finished(let s):
            switch s.verdict {
            case "passed": return .success
            case "failed": return .failure
            // verdict가 그 밖의 값(attention)이면 skip·xfail·xpass만 있거나 종료 코드가 0이 아닌 완료다.
            case .some: return .attention
            case nil:
                // 수집 오류는 사용자가 고쳐야 하는 실패라 넘어진 포즈를 쓴다(사용자 결정 2=B).
                // 테스트 없음·중단·미완료와 집계기가 모르는 새 상태 값은 성공으로 보지 않는다.
                return s.state == "collection_error" ? .failure : .attention
            }
        // 종료 이벤트 없이 끝난 실행(kill -9, 앱의 SIGKILL 등)은 미완료다. 실패로도 성공으로도 보지 않는다.
        case .incomplete: return .attention
        // 아래는 테스트 결과가 아니라 도구 쪽 문제다. 넘어진 포즈를 쓰면 "테스트가 실패했다"로 읽히므로 별도 상태로 둔다.
        case .collectionFailed, .aggregationFailed, .eventsMixed, .launchFailed: return .attention
        }
    }

    /// 지금 캐릭터가 보여 줄 값을 정한다.
    /// - Parameters:
    ///   - registry: 등록 정보. 등록에서 빠진 환경의 실행·결과는 따르지 않는다(제거한 환경 결과가 남아 보이지 않게).
    ///   - snapshot: 앱 실행과 터미널 실행을 합친 상태(RunSnapshot.merged의 결과). 앱 ▶와 터미널 실행이 같은 값을 따른다.
    /// - Returns: 캐릭터 상태. 실행도 결과도 없으면 .idle.
    /// 우선순위:
    /// 1. 살아 있음을 확인한 실행(앱 실행, pid로 확인한 터미널 실행)이 있으면 달리기. 여럿이면 가장 나중에 시작한 것.
    /// 2. 없으면 끝난 결과와 "상태 확인 불가" 터미널 실행 중 가장 나중 것. 결과는 끝난 시각, 확인 불가 실행은 시작 시각으로 비교한다.
    /// 확인 불가 실행(구버전 플러그인, pid 없음)을 달리기로 보이지 않는 이유: 이미 끝났을 수도 있다(행 문구도 "실행 중"이라 하지 않는다).
    public static func state(registry: Registry, snapshot: RunSnapshot) -> CharacterState {
        // 환경 id → (프로젝트, 환경). 등록 순서를 그대로 쓴다(시각이 같을 때 먼저 등록한 환경을 고르기 위함).
        var envs: [String: (project: Project, env: PMHEnvironment)] = [:]
        var order: [String] = []
        for project in registry.projects {
            for env in project.environments where envs[env.id] == nil {
                envs[env.id] = (project, env)
                order.append(env.id)
            }
        }

        // 1. 살아 있는 실행.
        // text는 행 문구와 같은 진행 글씨(캐릭터 아래 글씨와 도움말에 쓴다).
        struct Live { var envID: String; var runID: String; var startedAt: Date; var terminal: Bool; var text: String }
        var live: [Live] = []
        if let active = snapshot.active, envs[active.envID] != nil {
            // 앱 실행의 시작 시각이 없으면(테스트에서 만든 값) 가장 늦은 것으로 본다. 앱이 띄운 실행은 지금 돌고 있다는 것이 확실하다.
            live.append(Live(envID: active.envID, runID: active.runID, startedAt: active.startedAt ?? .distantFuture,
                             terminal: false, text: ResultPresentation.activeStatusText(active)))
        }
        var unknown: [ExternalActive] = []
        for envID in order {
            guard let ext = snapshot.external[envID] else { continue }
            if ext.statusKnown {
                live.append(Live(envID: envID, runID: ext.runID, startedAt: ext.startedAt ?? .distantPast,
                                 terminal: true, text: ResultPresentation.externalStatusText(ext)))
            } else {
                unknown.append(ext)
            }
        }
        // max(by:)는 같은 값이면 먼저 나온 것을 남긴다. 앱 실행을 맨 앞에 넣었으므로 시각이 같으면 앱 실행이 이긴다
        // (같은 시각은 실제로 거의 없다). 순서를 바꾸고 싶으면 여기서 비교 기준을 바꿔야 한다.
        if let latest = live.max(by: { $0.startedAt < $1.startedAt }), let entry = envs[latest.envID] {
            // key는 실행 id만 쓴다. 진행 글씨가 바뀌어도 key가 같아 달리기 애니메이션이 끊기지 않는다.
            return CharacterState(pose: .running, label: latest.text, envID: latest.envID, key: "run:\(latest.runID)",
                                  help: "\(entry.env.name) · \(latest.text)")
        }

        // 2. 끝난 결과와 상태 확인 불가 실행 중 가장 나중 것.
        var best: (time: Date, state: CharacterState)?
        for envID in order {
            guard let outcome = snapshot.results[envID], let entry = envs[envID] else { continue }
            // 끝난 시각을 모르는 결과(이전 형식 값)는 가장 이른 것으로 본다. 시각이 있는 결과가 있으면 그쪽을 따른다.
            let time = snapshot.finishedAt[envID] ?? .distantPast
            // 글씨는 행 문구와 같다(터미널 결과면 " · 터미널"이 붙는다).
            let label = ResultPresentation.resultStatusText(outcome, source: snapshot.sources[envID])
            let help = "\(entry.env.name) · \(label)"
            // 같은 환경에서 다음 결과가 나오면 끝난 시각이 바뀌어 key도 바뀐다(애니메이션을 처음부터 다시 재생).
            let key = "result:\(envID):\(time.timeIntervalSince1970)"
            let candidate = CharacterState(pose: pose(for: outcome), label: label, envID: envID, key: key, help: help)
            // 같은 시각이면 먼저 등록한 환경을 유지한다(>로 비교). 알림마다 캐릭터가 두 환경 사이를 오가지 않게 한다.
            if best == nil || time > best!.time { best = (time, candidate) }
        }
        for ext in unknown {
            guard let entry = envs[ext.envID] else { continue }
            let time = ext.startedAt ?? .distantPast
            // 글씨는 행 문구 "터미널 실행 · 상태 확인 불가"와 같다.
            let text = ResultPresentation.externalStatusText(ext)
            let candidate = CharacterState(pose: .attention, label: text, envID: ext.envID,
                                           key: "unknown:\(ext.runID)", help: "\(entry.env.name) · \(text)")
            if best == nil || time > best!.time { best = (time, candidate) }
        }
        return best?.state ?? .idle
    }
}

// MARK: 창 위치

/// 캐릭터 창의 위치 규칙. 좌표는 AppKit 화면 좌표(왼쪽 아래가 원점, 위로 갈수록 y가 크다)다.
public enum CharacterPlacement {
    /// 화면 가장자리와 띄우는 거리(pt).
    public static let margin: CGFloat = 20
    /// 누른 뒤 이만큼(pt) 넘게 움직여야 끌기로 본다. 그보다 작으면 클릭이다.
    /// 0으로 두면 손 떨림만으로도 끌기가 되어 클릭(팝오버 열기)이 잘 안 먹힌다.
    public static let dragThreshold: CGFloat = 3

    /// 기본 위치: 화면의 보이는 영역(메뉴 막대·Dock 제외) 오른쪽 아래.
    /// - Parameters: visibleFrame(NSScreen.visibleFrame), size(창 크기).
    /// - Returns: 창의 왼쪽 아래 좌표. 화면이 창보다 좁으면 왼쪽·아래 끝에 붙인다.
    public static func defaultOrigin(visibleFrame: CGRect, size: CGSize) -> CGPoint {
        let x = max(visibleFrame.minX, visibleFrame.maxX - size.width - margin)
        let y = min(visibleFrame.minY + margin, max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return CGPoint(x: x, y: y)
    }

    /// 저장한 위치를 지금 화면 배치에 맞춘다.
    /// - Parameters:
    ///   - origin: 저장한 창 왼쪽 아래 좌표.
    ///   - size: 창 크기.
    ///   - visibleFrames: 지금 연결된 화면들의 보이는 영역.
    /// - Returns: 창이 한 화면 안에 다 들어오게 옮긴 좌표. 저장한 위치가 어느 화면과도 겹치지 않으면 nil
    ///   (모니터를 뺐을 때 등). nil이면 호출하는 쪽이 주 화면 기본 위치를 쓴다.
    /// 겹치는 넓이가 가장 큰 화면 안으로 넣는 이유: 두 화면 경계에 걸쳐 둔 창을 사용자가 더 많이 보던 쪽에 남긴다.
    public static func clamp(origin: CGPoint, size: CGSize, visibleFrames: [CGRect]) -> CGPoint? {
        let rect = CGRect(origin: origin, size: size)
        var bestFrame: CGRect?
        var bestArea: CGFloat = 0
        for frame in visibleFrames {
            let overlap = rect.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea { bestArea = area; bestFrame = frame }
        }
        guard let frame = bestFrame else { return nil }
        // 창이 화면보다 크면 왼쪽·아래 끝에 맞춘다(max를 나중에 적용).
        let x = max(frame.minX, min(origin.x, frame.maxX - size.width))
        let y = max(frame.minY, min(origin.y, frame.maxY - size.height))
        return CGPoint(x: x, y: y)
    }

    /// 누른 곳에서 지금까지 움직인 거리로 끌기인지 정한다.
    /// - Parameters: dx, dy(누른 위치 기준 이동량, pt).
    /// - Returns: 기준(dragThreshold)을 넘으면 true.
    public static func isDrag(dx: CGFloat, dy: CGFloat) -> Bool {
        (dx * dx + dy * dy) > dragThreshold * dragThreshold
    }
}

// MARK: 캐릭터 페이지(WKWebView에 넣을 HTML)

/// 캐릭터를 그리는 HTML 페이지와, 포즈를 바꾸는 스크립트 문장을 만든다.
/// SVG를 <img>가 아니라 <template>에 그대로 넣는 이유: 실패·갸웃 포즈는 한 번만 움직이는 애니메이션이라
/// 새 결과마다 처음부터 다시 재생해야 한다. 템플릿을 복제해 넣으면 매번 새 요소라 애니메이션이 처음부터 돈다.
/// <img>는 같은 주소를 다시 넣어도 이미지 캐시 때문에 다시 재생되지 않을 수 있다.
/// 한 번에 한 포즈만 문서에 있으므로 SVG마다 같은 클래스 이름(.fox 등)과 id를 써도 서로 섞이지 않는다.
public enum CharacterPage {
    /// 캐릭터 그림 영역 아래 상태 글씨 자리의 높이(px). 창 높이 계산에도 쓴다.
    public static let labelHeight = 22
    /// 캐릭터 창 폭(pt). 상태 글씨를 모든 포즈에 보이면서 120에서 넓혔다. 긴 행 문구도 대부분 한 줄에 들어간다.
    public static let windowWidth = 168

    /// 페이지 전체 HTML.
    /// - Parameter svgs: 포즈 → SVG 원문. 빠진 포즈는 빈 템플릿이 되어 그 포즈에서는 상태 글씨만 보인다
    ///   (에셋이 번들에 없어도 앱이 멈추지 않게).
    /// - Returns: 배경이 투명한 HTML 문서. setPose(pose, label, key) 함수를 갖는다.
    public static func html(svgs: [CharacterPose: String]) -> String {
        let templates = CharacterPose.allCases.map { pose in
            "<template id=\"pose-\(pose.rawValue)\">\(svgs[pose] ?? "")</template>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
          /* 사용자가 글씨나 그림을 드래그해 선택하지 못하게 한다(창 끌기는 앱 쪽 투명 뷰가 처리한다). */
          body { -webkit-user-select: none; user-select: none; cursor: default; }
          #stage { position: absolute; left: 0; right: 0; top: 0; bottom: \(labelHeight)px;
                   display: flex; align-items: flex-end; justify-content: center; }
          #stage svg { width: 100%; height: 100%; display: block; }
          #label { position: absolute; left: 50%; bottom: 2px; transform: translateX(-50%);
                   max-width: 96%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
                   font: 600 11px -apple-system, "Apple SD Gothic Neo", sans-serif; color: #563C39;
                   background: rgba(255, 240, 215, .96); border: 1.5px solid #563C39; border-radius: 9px;
                   padding: 1px 8px; box-sizing: border-box; }
          #label[hidden] { display: none; }
        </style></head>
        <body>
        <div id="stage"></div><div id="label" hidden></div>
        \(templates)
        <script>
          var currentKey = null;
          // 포즈를 바꾼다. key가 같으면 그림을 그대로 두고 글씨만 고친다(재생 중인 애니메이션을 끊지 않기 위함).
          function setPose(pose, label, key) {
            if (key !== currentKey) {
              currentKey = key;
              var stage = document.getElementById('stage');
              var t = document.getElementById('pose-' + pose);
              stage.replaceChildren();
              if (t) {
                stage.appendChild(t.content.cloneNode(true));
                var svg = stage.querySelector('svg');
                // 아래쪽에 맞춘다. 실패 포즈(320x190)는 가로로 길어 가운데 맞춤이면 공중에 뜬 것처럼 보인다.
                if (svg) { svg.setAttribute('preserveAspectRatio', 'xMidYMax meet'); }
              }
              stage.dataset.pose = pose;
            }
            var el = document.getElementById('label');
            if (label) { el.textContent = label; el.hidden = false; } else { el.textContent = ''; el.hidden = true; }
            return pose;
          }
        </script>
        </body></html>
        """
    }

    /// 상태를 페이지에 넣는 스크립트 문장.
    /// - Parameter state: 캐릭터 상태.
    /// - Returns: 예: setPose("failure",null,"result:e:12.0")
    /// 문자열을 JSON으로 바꿔 넣는 이유: 환경 이름이나 글씨에 따옴표·역슬래시가 있어도 스크립트가 깨지지 않게 한다.
    public static func script(for state: CharacterState) -> String {
        func literal(_ value: String?) -> String {
            guard let value = value else { return "null" }
            // 배열로 감싸 직렬화한 뒤 대괄호를 떼면, 최상위 문자열을 받지 않는 옛 Foundation에서도 같은 결과가 나온다.
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return String(text.dropFirst().dropLast())
        }
        return "setPose(\(literal(state.pose.rawValue)),\(literal(state.label)),\(literal(state.key)))"
    }
}
