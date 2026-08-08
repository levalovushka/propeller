import AppKit

/// Фильтр «есть ли такое слово в русском языке».
///
/// Читает слова из stdin по одному в строке, печатает те, которых русская
/// орфография не знает. Это и есть кандидаты: термины, англицизмы, имена и
/// поломки распознавания — всё, чего в обычном русском корпусе не бывает.
///
/// Проверка встроена в macOS (`NSSpellChecker`), поэтому ничего не скачивается и
/// работает офлайн. Словарь у неё не строгий — «пайплайн» и «инстанс» она уже
/// знает как заимствования, — но «майплайн» и «дискриптор» отсеивает, а именно
/// это здесь и нужно.
///
/// Используется из `vocab/mine.py`, в приложение не входит.
let checker = NSSpellChecker.shared
guard checker.availableLanguages.contains("ru") else {
    FileHandle.standardError.write(Data("русской орфографии в системе нет\n".utf8))
    exit(1)
}

while let line = readLine(strippingNewline: true) {
    let word = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { continue }
    let range = checker.checkSpelling(
        of: word, startingAt: 0, language: "ru", wrap: false,
        inSpellDocumentWithTag: 0, wordCount: nil
    )
    if range.location != NSNotFound {
        print(word)
    }
}
