// EventTail.swift
// 실행 중에 계속 늘어나는 JSONL 이벤트 파일을 "읽은 위치 이후"부터 이어 읽는 코드.
// 입력: 이벤트 파일 경로(파일은 아직 없을 수 있다).
// 출력: 줄바꿈으로 끝난 완성된 줄(바이트)의 목록. 미완성 마지막 조각은 다음 읽기까지 보류한다.
// 주의: 문자열이 아니라 바이트로 처리한다. 읽기 경계가 한글 중간이어도 글자가 깨지지 않게 하기 위함이다.

import Foundation

/// 바이트 단위 줄 분리기. 줄바꿈(0x0A)으로 끝난 줄만 내보내고 마지막 조각은 다음 입력까지 보류한다.
/// 0x0A는 UTF-8 다중 바이트 문자 안에 나타나지 않으므로 읽기 경계가 한글 중간이어도 깨지지 않는다.
public struct LineSplitter {
    public private(set) var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            let line = pending[start..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        return lines
    }

    public mutating func reset() { pending = Data() }
}

/// 이벤트 파일을 읽은 위치부터 이어서 읽는다(이미 읽은 부분은 다시 읽지 않는다).
public struct EventTail {
    public let url: URL
    public private(set) var offset: UInt64 = 0
    public private(set) var fileSeen = false
    private var splitter = LineSplitter()

    public init(url: URL) { self.url = url }

    /// 보류 중인 미완성 조각의 바이트 수(줄바꿈 없이 끝난 마지막 조각).
    public var pendingBytes: Int { splitter.pending.count }

    public mutating func read() -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        fileSeen = true
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { // 파일이 줄었으면 처음부터 다시 읽는다.
            offset = 0
            splitter.reset()
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        return splitter.append(data)
    }
}
