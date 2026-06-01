// AppController.j
// Cappuccino Frontend for Email Archive Assistant
// (c) 2026 by Daniel Böhringer

@import <AppKit/AppKit.j>
@import <Foundation/CPObject.j>

var BackendBaseURL = @"";

// --- SUBCLASS: TABLE MATRIX VIEW (DYNAMIC TEXT-VIEW ENGINE) ---
@implementation TableMatrixView : CPView
{
    CPArray _headers;
    CPArray _rows;
}

- (id)initWithHeaders:(CPArray)headers rows:(CPArray)rows width:(float)totalWidth
{
    self = [super initWithFrame:CGRectMake(0, 0, totalWidth, 20)];
    if (self)
    {
        _headers = headers;
        _rows = rows;
        
        var numCols = [headers count];

        if (numCols == 0 && [rows count] > 0)
            numCols = [[rows objectAtIndex:0] count];

        // Äußerer oberer und linker Rand für die Tabelle selbst (Kollabierte Rahmen)
        if (self._DOMElement) {
            self._DOMElement.style.borderTop = "1px solid #e0e0e0";
            self._DOMElement.style.borderLeft = "1px solid #e0e0e0";
        }

        // Zellen initial erstellen
        if ([headers count] > 0) {
            for (var c = 0; c < numCols; c++) {
                var headerText = [headers objectAtIndex:c];
                var cellView = [self createCellWithText:headerText frame:CGRectMakeZero() isHeader:YES];
                [self addSubview:cellView];
            }
        }
        
        for (var r = 0; r < [rows count]; r++) {
            var rowData = [rows objectAtIndex:r];
            for (var c = 0; c < numCols; c++) {
                var cellText = @"";

                if (c < [rowData count])
                    cellText = [rowData objectAtIndex:c];

                var cellView = [self createCellWithText:cellText frame:CGRectMakeZero() isHeader:NO];
                [self addSubview:cellView];
            }
        }
        
        [self resizeToWidth:totalWidth];
    }
    return self;
}

- (CPView)createCellWithText:(CPString)text frame:(CGRect)frame isHeader:(BOOL)isHeader
{
    // Verhindert den Zero-Width Bug bei der Initialisierung
    var initialWidth = (frame.size.width > 0) ? frame.size.width : 120.0;
    var initialHeight = (frame.size.height > 0) ? frame.size.height : 28.0;

    var cellContainer = [[CPView alloc] initWithFrame:CGRectMake(frame.origin.x, frame.origin.y, initialWidth, initialHeight)];
    [cellContainer setBackgroundColor:isHeader ? [CPColor colorWithWhite:0.92 alpha:1.0] : [CPColor whiteColor]];
    
    // Rahmen nur rechts und unten zeichnen (Vermeidet doppelte Linien im Raster)
    var borderView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, initialWidth, initialHeight)];
    [borderView setBackgroundColor:[CPColor clearColor]];
    [borderView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    if (borderView._DOMElement) {
        borderView._DOMElement.style.borderBottom = "1px solid #e0e0e0";
        borderView._DOMElement.style.borderRight = "1px solid #e0e0e0";
        borderView._DOMElement.style.boxSizing = "border-box";
    }
    [cellContainer addSubview:borderView];
    
    // CPTextView zur korrekten Rich-Text-Darstellung mit sicherem Start-Maß erstellen
    var textContainer = [[CPTextContainer alloc] initWithContainerSize:CGSizeMake(initialWidth - 8, 1e7)];
    var textView = [[CPTextView alloc] initWithFrame:CGRectMake(4, 2, initialWidth - 8, initialHeight - 4) textContainer:textContainer];
    [textView setEditable:NO];
    [textView setSelectable:YES];
    [textView setBackgroundColor:[CPColor clearColor]];
    [textView setVerticallyResizable:YES];
    [textView setHorizontallyResizable:NO];
    [[textView textContainer] setWidthTracksTextView:YES];
    
    // Parsen von Inline-Elementen (z.B. **fett**) innerhalb von Tabellenzellen
    var parsedText = [MarkdownParser parseInlineMarkdown:text isHeader:isHeader headerLevel:3];
    
    var storage = [textView textStorage];
    if (storage && [storage respondsToSelector:@selector(setAttributedString:)]) {
        [storage setAttributedString:parsedText];
    } else {
        [textView setEditable:YES];
        [textView setString:@""];
        [textView insertText:parsedText];
        [textView setEditable:NO];
    }
    
    [cellContainer addSubview:textView];
    return cellContainer;
}

// Hilfsfunktion: Sucht die CPTextView aus dem Zellen-Container heraus
- (CPTextView)getTextViewFromCell:(CPView)cellView
{
    var subviews = [cellView subviews];
    for (var i = 0; i < [subviews count]; i++) {
        var sub = [subviews objectAtIndex:i];
        if ([sub isKindOfClass:[CPTextView class]]) {
            return sub;
        }
    }
    return nil;
}

// Berechnet Spaltenbreiten und Zeilenhöhen auf Pixelbasis neu
- (void)resizeToWidth:(float)newWidth
{
    var numCols = [_headers count];
    if (numCols == 0 && [_rows count] > 0) {
        numCols = [[_rows objectAtIndex:0] count];
    }
    if (numCols == 0) return;
    
    var subviews = [self subviews];
    
    // 1. Spalten-Arrays initialisieren
    var colNaturalWidths = []; // Ideale Breite ohne Zeilenumbruch
    var colMinWidths = [];     // Minimale Breite, damit kein einzelnes Wort umbricht
    for (var c = 0; c < numCols; c++) {
        colNaturalWidths[c] = 80.0; 
        colMinWidths[c] = 60.0;
    }
    
    // Hilfs-TextField für Plaintext-Messungen
    var measureTextField = [[CPTextField alloc] initWithFrame:CGRectMake(0, 0, 10000.0, 24.0)];
    [measureTextField setFont:[CPFont systemFontOfSize:13.0]];
    
    // Hilfs-Block zur Ermittlung der minimalen Wort-Breiten und maximalen Natural-Breiten
    var measureCell = function(cellText, isHeader, colIndex) {
        var parsedText = [MarkdownParser parseInlineMarkdown:cellText isHeader:isHeader headerLevel:3];
        [measureTextField setFont:isHeader ? [CPFont boldSystemFontOfSize:11.0] : [CPFont systemFontOfSize:11.0]];
        
        // A. Natural-Width messen (Vollständig unumbrochener Gesamttext)
        [measureTextField setStringValue:[parsedText string]];
        [measureTextField sizeToFit];
        var naturalW = CGRectGetWidth([measureTextField frame]) + 24.0;
        if (naturalW > colNaturalWidths[colIndex]) {
            colNaturalWidths[colIndex] = naturalW;
        }
        
        // B. Absolute Min-Width messen (Das längste Einzelwort bestimmt das Limit)
        var words = cellText.split(/[\s\-]/); // Trennung bei Whitespace oder Bindestrich
        var maxWordW = 50.0;
        for (var w = 0; w < words.length; w++) {
            var word = words[w].trim();
            if (word.length === 0) continue;
            [measureTextField setStringValue:word];
            [measureTextField sizeToFit];
            var wordW = CGRectGetWidth([measureTextField frame]) + 30.0; // Margin + Padding
            if (wordW > maxWordW) {
                maxWordW = wordW;
            }
        }
        if (maxWordW > colMinWidths[colIndex]) {
            colMinWidths[colIndex] = maxWordW;
        }
    };
    
    // Header-Spalten vermessen
    for (var c = 0; c < [_headers count]; c++) {
        measureCell([_headers objectAtIndex:c], YES, c);
    }
    
    // Datenzellen vermessen
    for (var r = 0; r < [_rows count]; r++) {
        var rowData = [_rows objectAtIndex:r];
        for (var c = 0; c < numCols; c++) {
            var cellText = @"";
            if (c < [rowData count]) {
                cellText = [rowData objectAtIndex:c];
            }
            measureCell(cellText, NO, c);
        }
    }
    
    // 2. Intelligente Breiten-Verteilung mit Min-Width-Constraint
    var totalMinWidth = 0.0;
    for (var c = 0; c < numCols; c++) {
        totalMinWidth += colMinWidths[c];
    }
    
    var colWidths = [];
    
    if (newWidth <= totalMinWidth) {
        // Fallback bei extrem engem Fenster
        var remainingWidth = newWidth;
        for (var c = 0; c < numCols; c++) {
            var w = Math.floor((colMinWidths[c] / totalMinWidth) * newWidth);
            colWidths[c] = w;
            remainingWidth -= w;
        }
        if (numCols > 0) colWidths[numCols - 1] += remainingWidth;
    } else {
        // Normalfall: Jede Spalte erhält garantiert ihr Minimum. Der verbleibende Platz
        // wird proportional anhand der noch benötigten Wachstumskapazität verteilt.
        for (var c = 0; c < numCols; c++) {
            colWidths[c] = colMinWidths[c];
        }
        
        var totalGrowthCapacity = 0.0;
        var growthCapacities = [];
        for (var c = 0; c < numCols; c++) {
            var capacity = Math.max(0.0, colNaturalWidths[c] - colMinWidths[c]);
            growthCapacities[c] = capacity;
            totalGrowthCapacity += capacity;
        }
        
        var extraWidth = newWidth - totalMinWidth;
        var remainingExtra = extraWidth;
        
        for (var c = 0; c < numCols; c++) {
            if (totalGrowthCapacity > 0) {
                var w = Math.floor((growthCapacities[c] / totalGrowthCapacity) * extraWidth);
                colWidths[c] += w;
                remainingExtra -= w;
            }
        }
        if (numCols > 0) {
            colWidths[numCols - 1] += remainingExtra;
        }
    }
    
    var cellIndex = 0;
    var currentY = 0;
    
    // Hilfsfunktion: Zeilenhöhe dynamisch über den LayoutManager messen
    var layoutRow = function(startIndex) {
        var maxCellHeight = 28.0; 
        
        // Erster Durchlauf: Breite zuweisen und exakte Höhe des umgebrochenen Texts berechnen
        for (var c = 0; c < numCols; c++) {
            var idx = startIndex + c;
            if (idx < [subviews count]) {
                var cellView = [subviews objectAtIndex:idx];
                var textView = [self getTextViewFromCell:cellView];
                if (textView) {
                    var targetWidth = Math.max(10.0, colWidths[c] - 8);
                    [[textView textContainer] setContainerSize:CGSizeMake(targetWidth, 1e7)];
                    
                    var usedRect = [[textView layoutManager] usedRectForTextContainer:[textView textContainer]];
                    var wrappedHeight = CGRectGetHeight(usedRect) + 12.0; // Sicherheits-Padding
                    if (wrappedHeight > maxCellHeight) {
                        maxCellHeight = wrappedHeight;
                    }
                }
            }
        }
        
        // Zweiter Durchlauf: Container platzieren und Textfelder einpassen
        var currentX = 0;
        for (var c = 0; c < numCols; c++) {
            var idx = startIndex + c;
            if (idx < [subviews count]) {
                var cellView = [subviews objectAtIndex:idx];
                [cellView setFrame:CGRectMake(currentX, currentY, colWidths[c], maxCellHeight)];
                
                var textView = [self getTextViewFromCell:cellView];
                if (textView) {
                    var targetWidth = Math.max(10.0, colWidths[c] - 8);
                    
                    var textY = 4.0;
                    var finalTextViewHeight = maxCellHeight - 8.0;
                    [textView setFrame:CGRectMake(4, textY, targetWidth, finalTextViewHeight)];
                }
                
                // Border-View anpassen
                var cellSubviews = [cellView subviews];
                if ([cellSubviews count] > 0) {
                    [[cellSubviews objectAtIndex:0] setFrame:CGRectMake(0, 0, colWidths[c], maxCellHeight)];
                }
            }
            currentX += colWidths[c];
        }
        
        return maxCellHeight;
    };
    
    // Header-Zeile berechnen
    if ([_headers count] > 0) {
        var headerHeight = layoutRow(cellIndex);
        cellIndex += numCols;
        currentY += headerHeight;
    }
    
    // Daten-Zeilen nacheinander berechnen
    for (var r = 0; r < [_rows count]; r++) {
        var rowHeight = layoutRow(cellIndex);
        cellIndex += numCols;
        currentY += rowHeight;
    }
    
    [self setFrameSize:CGSizeMake(newWidth, currentY)];
}

@end

// --- MARKDOWN PARSER CLASS ---
@implementation MarkdownParser : CPObject

+ (CPAttributedString)attributedStringFromMarkdown:(CPString)markdown
{
    if (!markdown) {
        return [[CPAttributedString alloc] initWithString:@""];
    }

    var result = [[CPMutableAttributedString alloc] initWithString:@""];
    var lines = markdown.split(/\r?\n/);
    
    var i = 0;
    while (i < lines.length) {
        var line = lines[i];
        
        // Tabellen-Erkennung
        if ([self isTableHeaderLine:line] && i + 1 < lines.length && [self isTableSeparatorLine:lines[i+1]]) {
            var headers = [self parseTableCells:line];
            var separatorLine = lines[i+1];
            var rows = [CPMutableArray array];
            
            i += 2;
            while (i < lines.length && [self isTableRowLine:lines[i]]) {
                [rows addObject:[self parseTableCells:lines[i]]];
                i++;
            }
            
            var numCols = [headers count];
            if (numCols == 0 && [rows count] > 0) {
                numCols = [[rows objectAtIndex:0] count];
            }
            
            // 1. Zuerst die absolute Summe der Natural-Breiten zur Spalten-Proportionsbestimmung ermitteln
            var totalNaturalW = 0.0;
            var colNaturalWidths = [];
            var measureTextField = [[CPTextField alloc] initWithFrame:CGRectMake(0, 0, 10000.0, 24.0)];
            [measureTextField setFont:[CPFont systemFontOfSize:11.0]];
            
            for (var c = 0; c < numCols; c++) {
                var cellW = 80.0;
                
                // Headers prüfen
                if (c < headers.length) {
                    var parsedText = [self parseInlineMarkdown:headers[c] isHeader:YES headerLevel:3];
                    [measureTextField setStringValue:[parsedText string]];
                    [measureTextField sizeToFit];
                    cellW = Math.max(cellW, CGRectGetWidth([measureTextField frame]) + 24.0);
                }
                
                // Reihen prüfen
                for (var r = 0; r < [rows count]; r++) {
                    var rowData = [rows objectAtIndex:r];
                    if (c < [rowData count]) {
                        var parsedText = [self parseInlineMarkdown:rowData[c] isHeader:NO headerLevel:3];
                        [measureTextField setStringValue:[parsedText string]];
                        [measureTextField sizeToFit];
                        cellW = Math.max(cellW, CGRectGetWidth([measureTextField frame]) + 24.0);
                    }
                }
                colNaturalWidths[c] = cellW;
                totalNaturalW += cellW;
            }
            
            // 2. Präzise adaptive Zeilenhöhen-Schätzung für das Newline-Sizing (Verhindert zu große Abstände)
            var estimatedHeight = 36.0; // Startwert für Header-Zeile mit Padding
            for (var r = 0; r < [rows count]; r++) {
                var rowData = [rows objectAtIndex:r];
                var maxCellHeight = 28.0;
                
                for (var c = 0; c < numCols; c++) {
                    var cellText = @"";
                    if (c < [rowData count]) {
                        cellText = [rowData objectAtIndex:c];
                    }
                    var charCount = cellText.length;
                    
                    // Schätzung basierend auf realistischer Spaltenbreitenverteilung
                    var proportion = totalNaturalW > 0 ? (colNaturalWidths[c] / totalNaturalW) : (1.0 / numCols);
                    var estimatedColWidth = proportion * 500.0;
                    var charsPerLine = Math.max(10.0, Math.floor(estimatedColWidth / 6.5)); // ca. 6.5px pro Zeichen
                    
                    var estimatedLines = Math.ceil(charCount / charsPerLine);
                    if (estimatedLines < 1) estimatedLines = 1;
                    
                    var cellHeight = (estimatedLines * 16.0) + 12.0;
                    if (cellHeight > maxCellHeight) {
                        maxCellHeight = cellHeight;
                    }
                }
                estimatedHeight += maxCellHeight;
            }
            
            // Berechne die benötigten Leerzeilen (\n Zeilenhöhe ist ca. 16px)
            var lineCount = Math.ceil(estimatedHeight / 16.0) + 1; // Minimaler Sicherheitsabstand (+1)
            var newlineStr = "";
            for (var nl = 0; nl < lineCount; nl++) {
                newlineStr += "\n";
            }
            
            var tableAttrStr = [[CPMutableAttributedString alloc] initWithString:newlineStr];
            var matrixView = [[TableMatrixView alloc] initWithHeaders:headers rows:rows width:500.0];
            
            [tableAttrStr addAttribute:@"TableAttachmentAttribute" value:matrixView range:CPMakeRange(0, [tableAttrStr length])];
            [result appendAttributedString:tableAttrStr];
            continue;
        }
        
        var isHeader = false;
        var headerLevel = 0;
        
        // Überschriften (#)
        var headerMatch = line.match(/^(#{1,6})\s+(.*)$/);
        if (headerMatch) {
            headerLevel = headerMatch[1].length;
            line = headerMatch[2];
            isHeader = true;
        }
        
        // Listenpunkte (- oder *)
        var isListItem = false;
        var listMatch = line.match(/^(\*|-)\s+(.*)$/);
        if (listMatch) {
            line = "  • " + listMatch[2];
            isListItem = true;
        }
        
        var parsedLine = [self parseInlineMarkdown:line isHeader:isHeader headerLevel:headerLevel];
        [result appendAttributedString:parsedLine];
        
        if (i < lines.length - 1) {
            [result appendAttributedString:[[CPAttributedString alloc] initWithString:@"\n"]];
        }
        
        i++;
    }
    
    return result;
}

+ (BOOL)isTableHeaderLine:(CPString)line
{
    var trimmed = line.trim();
    return trimmed.indexOf('|') !== -1;
}

+ (BOOL)isTableSeparatorLine:(CPString)line
{
    var trimmed = line.trim();
    if (trimmed.indexOf('|') === -1) return NO;
    var stripped = trimmed.replace(/[\s|:\-]/g, '');
    return stripped.length === 0;
}

+ (BOOL)isTableRowLine:(CPString)line
{
    var trimmed = line.trim();
    return trimmed.indexOf('|') !== -1;
}

+ (CPArray)parseTableCells:(CPString)line
{
    var parts = line.split('|');
    var cells = [CPMutableArray array];
    var startIdx = 0;
    var endIdx = parts.length;
    if (parts[0].trim() === "") startIdx = 1;
    if (parts[parts.length - 1].trim() === "") endIdx = parts.length - 1;
    
    for (var j = startIdx; j < endIdx; j++) {
        [cells addObject:parts[j].trim()];
    }
    return cells;
}

+ (CPAttributedString)parseInlineMarkdown:(CPString)text isHeader:(BOOL)isHeader headerLevel:(int)level
{
    var baseFontSize = 11.0;
    var fontSize = baseFontSize;
    var isBold = isHeader;
    var isItalic = NO;
    
    if (isHeader) {
        if (level == 1) fontSize = 15.0;
        else if (level == 2) fontSize = 13.0;
        else fontSize = 12.0;
    }
    
    var result = [[CPMutableAttributedString alloc] initWithString:@""];
    var currentSegment = "";
    var i = 0;
    var len = text.length;
    
    var defaultFont = [CPFont systemFontOfSize:fontSize];
    if (isBold) {
        defaultFont = [CPFont boldSystemFontOfSize:fontSize];
    }
    
    while (i < len) {
        if (i + 2 < len && text.substr(i, 3) === "***") {
            if (currentSegment.length > 0) {
                [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
                currentSegment = "";
            }
            isBold = !isBold;
            isItalic = !isItalic;
            i += 3;
            continue;
        }
        if (i + 1 < len && text.substr(i, 2) === "**") {
            if (currentSegment.length > 0) {
                [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
                currentSegment = "";
            }
            isBold = !isBold;
            i += 2;
            continue;
        }
        if (text.charAt(i) === "*") {
            if (currentSegment.length > 0) {
                [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
                currentSegment = "";
            }
            isItalic = !isItalic;
            i++;
            continue;
        }
        if (text.charAt(i) === "`") {
            if (currentSegment.length > 0) {
                [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
                currentSegment = "";
            }
            var codeText = "";
            i++;
            while (i < len && text.charAt(i) !== "`") {
                codeText += text.charAt(i);
                i++;
            }
            [result appendAttributedString:[self attributedStringWithText:codeText font:defaultFont bold:NO italic:NO code:YES]];
            i++;
            continue;
        }
        
        currentSegment += text.charAt(i);
        i++;
    }
    
    if (currentSegment.length > 0) {
        [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
    }
    
    return result;
}

+ (CPAttributedString)attributedStringWithText:(CPString)text font:(CPFont)baseFont bold:(BOOL)b italic:(BOOL)it code:(BOOL)c
{
    var fontName = [baseFont familyName];
    var fontSize = [baseFont size]; 
    var finalFont = baseFont;
    
    if (c) {
        finalFont = [CPFont fontWithName:@"Courier" size:fontSize];
    } else {
        finalFont = [CPFont _fontWithName:fontName size:fontSize bold:b italic:it];
    }
    
    if (!finalFont) {
        finalFont = [CPFont systemFontOfSize:fontSize];
    }
    
    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
        finalFont, CPFontAttributeName,
        [CPColor blackColor], CPForegroundColorAttributeName
    ];
    return [[CPAttributedString alloc] initWithString:text attributes:dict];
}

@end

// --- SUBCLASS: SPEECH BUBBLE VIEW ---
@implementation SpeechBubbleBox : CPView
{
    BOOL    _isUser;
    CPColor _bubbleColor;
}

- (id)initWithFrame:(CGRect)aFrame isUser:(BOOL)isUser fillColor:(CPColor)aColor
{
    self = [super initWithFrame:aFrame];
    if (self) {
        _isUser = isUser;
        _bubbleColor = aColor;
        [self setAutoresizingMask:CPViewWidthSizable];
    }
    return self;
}

- (void)drawRect:(CGRect)aRect
{
    var context = [[CPGraphicsContext currentContext] graphicsPort];
    var bounds = [self bounds];
    var w = CGRectGetWidth(bounds);
    var h = CGRectGetHeight(bounds) - 10.0;
    var r = 6.0;   
    var th = 10.0; 

    CGContextBeginPath(context);
    CGContextMoveToPoint(context, r, 0);
    CGContextAddLineToPoint(context, w - r, 0);
    CGContextAddArcToPoint(context, w, 0, w, r, r);
    CGContextAddLineToPoint(context, w, h - r);
    CGContextAddArcToPoint(context, w, h, w - r, h, r);
    
    if (_isUser) {
        CGContextAddLineToPoint(context, w - 21, h);
        CGContextAddLineToPoint(context, w - 21, h + th);
        CGContextAddLineToPoint(context, w - 35, h);
        CGContextAddLineToPoint(context, r, h);
    } else {
        CGContextAddLineToPoint(context, 35, h);
        CGContextAddLineToPoint(context, 21, h + th);
        CGContextAddLineToPoint(context, 21, h);
        CGContextAddLineToPoint(context, r, h);
    }
    
    CGContextAddArcToPoint(context, 0, h, 0, h - r, r);
    CGContextAddLineToPoint(context, 0, r);
    CGContextAddArcToPoint(context, 0, 0, r, 0, r);
    CGContextClosePath(context);
    
    CGContextSetFillColor(context, _bubbleColor);
    CGContextFillPath(context);
    
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, r, 0);
    CGContextAddLineToPoint(context, w - r, 0);
    CGContextAddArcToPoint(context, w, 0, w, r, r);
    CGContextAddLineToPoint(context, w, h - r);
    CGContextAddArcToPoint(context, w, h, w - r, h, r);
    
    if (_isUser) {
        CGContextAddLineToPoint(context, w - 21, h);
        CGContextAddLineToPoint(context, w - 21, h + th);
        CGContextAddLineToPoint(context, w - 35, h);
        CGContextAddLineToPoint(context, r, h);
    } else {
        CGContextAddLineToPoint(context, 35, h);
        CGContextAddLineToPoint(context, 21, h + th);
        CGContextAddLineToPoint(context, 21, h);
        CGContextAddLineToPoint(context, r, h);
    }
    
    CGContextAddArcToPoint(context, 0, h, 0, h - r, r);
    CGContextAddLineToPoint(context, 0, r);
    CGContextAddArcToPoint(context, 0, 0, r, 0, r);
    CGContextClosePath(context);
    
    CGContextSetStrokeColor(context, [CPColor colorWithWhite:0.8 alpha:1.0]);
    CGContextSetLineWidth(context, 1.0);
    CGContextStrokePath(context);
}

@end

@implementation UploadDropTableView : CPTableView
@end

@implementation UploadDropButton : CPButton
@end

// --- MAIN CONTROLLER ---
@implementation AppController : CPObject
{
    CPWindow            _mainWindow;
    UploadDropTableView _summaryTableView;
    CPScrollView        _summaryScrollView;
    
    CPScrollView        _chatScrollView;
    CPView              _chatDocumentView;
    CPTextField         _chatInputField;
    CPButton            _chatSendButton;
    
    CPCheckBox          _mailboxConstraintCheckbox; 
    CPProgressIndicator _progressBar;
    CPTextField         _statusLabel;

    CPWindow            _settingsWindow;
    CPPopUpButton       _servicePopUp;
    CPTextField         _endpointField;
    CPTextField         _modelField;
    CPTextField         _apiKeyField;
    CPTextField         _maxStepsField;

    CPWindow            _historySheetWindow;
    CPTextView          _historySheetTextView;

    CPString            _currentSessionId;
    float               _currentChatY;
    
    CPMutableArray      _chatMessages; 
    CPMutableArray      _summaryRows;     
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    _chatMessages = [CPMutableArray array];
    _summaryRows = [CPMutableArray array];

    var defaults = [CPUserDefaults standardUserDefaults];
    var defaultSettings = [CPDictionary dictionaryWithObjects:[
        @"ollama",
        @"http://localhost:11434/api/generate",
        @"gemma4:e4b",
        @"",
        @"llama-3.1-8b-instant",
        @"",
        @"gemini-2.5-flash",
        @"",
        @"google/gemini-2.0-flash-001",
        @"5"
    ] forKeys:[
        @"LLMServiceType",
        @"LLMOllamaEndpoint",
        @"LLMOllamaModel",
        @"LLMGroqAPIKey",
        @"LLMGroqModel",
        @"LLMGeminiAPIKey",
        @"LLMGeminiModel",
        @"LLMOpenRouterAPIKey",
        @"LLMOpenRouterModel",
        @"LLMMaxSteps"
    ]];
    [defaults registerDefaults:defaultSettings];

    // --- SETUP REAL SYSTEM MENU BAR ---
    var mainMenu = [CPApp mainMenu];
    while ([mainMenu numberOfItems] > 0) {
        [mainMenu removeItemAtIndex:0];
    }

    // 1. MailArchivist App Menu
    var appMenuItem = [mainMenu insertItemWithTitle:@"MailArchivist" action:nil keyEquivalent:nil atIndex:0];
    var appMenu = [[CPMenu alloc] initWithTitle:@"MailArchivist"];
    [appMenu addItemWithTitle:@"About MailArchivist" action:nil keyEquivalent:nil];
    [appMenu addItem:[CPMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"New Session" action:@selector(newSessionAction:) keyEquivalent:@"n"];
    [appMenu addItemWithTitle:@"Transfer History..." action:@selector(openHistorySheet:) keyEquivalent:@"t"];
    [appMenu addItemWithTitle:@"Settings..." action:@selector(openSettingsSheet:) keyEquivalent:@","];
    [mainMenu setSubmenu:appMenu forItem:appMenuItem];

    // 2. Edit Menu
    var editMenuItem = [mainMenu insertItemWithTitle:@"Edit" action:nil keyEquivalent:nil atIndex:1];
    var editMenu = [[CPMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [mainMenu setSubmenu:editMenu forItem:editMenuItem];

    [CPMenu setMenuBarVisible:YES];

    // --- MAIN WINDOW CONFIGURATION ---
    _mainWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1150, 780) styleMask:CPBorderlessBridgeWindowMask];
    [_mainWindow setTitle:@"MailArchivist"];
    [_mainWindow center];

    var contentView = [_mainWindow contentView];
    var bounds = [contentView bounds];

    // --- SPLIT-VIEW WORKSPACE (100% Window Height) ---
    var splitHeight = CGRectGetHeight(bounds);
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), splitHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];

    var dividerWidth = [splitView dividerThickness];
    var leftWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) * 0.35;
    var rightWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) - leftWidth;

    // LINKS: Folder structure view
    var leftContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [leftContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [leftContainer setBackgroundColor:[CPColor colorWithWhite:0.97 alpha:1.0]];

    _summaryScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight - 45)];
    [_summaryScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_summaryScrollView setAutohidesScrollers:YES];

    _summaryTableView = [[UploadDropTableView alloc] initWithFrame:[_summaryScrollView bounds]];
    [_summaryTableView setUsesAlternatingRowBackgroundColors:YES];
    [_summaryTableView setCornerView:nil];
    [_summaryTableView setDataSource:self];

    // Column 1: Mailbox Folder
    var colMailbox = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[colMailbox headerView] setStringValue:@"Mailbox"];
    [colMailbox setWidth:leftWidth - 140];
    [colMailbox setMinWidth:50];
    [_summaryTableView addTableColumn:colMailbox];

    // Column 2: Total Indexed Message Count
    var colTotal = [[CPTableColumn alloc] initWithIdentifier:@"totalCount"];
    [[colTotal headerView] setStringValue:@"Indexed"];
    [colTotal setWidth:60];
    [colTotal setMinWidth:40];
    [_summaryTableView addTableColumn:colTotal];

    // Column 3: Unread Count
    var colUnread = [[CPTableColumn alloc] initWithIdentifier:@"unreadCount"];
    [[colUnread headerView] setStringValue:@"Unread"];
    [colUnread setWidth:60];
    [colUnread setMinWidth:40];
    [_summaryTableView addTableColumn:colUnread];

    [_summaryScrollView setDocumentView:_summaryTableView];
    [leftContainer addSubview:_summaryScrollView];

    // CheckBox links direkt unter der Tabelle positioniert
    _mailboxConstraintCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(15, splitHeight - 35, leftWidth - 30, 24)];
    [_mailboxConstraintCheckbox setTitle:@"Search selected mailbox only"];
    [_mailboxConstraintCheckbox setFont:[CPFont systemFontOfSize:11.0]];
    [_mailboxConstraintCheckbox setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin];
    [leftContainer addSubview:_mailboxConstraintCheckbox];

    [splitView addSubview:leftContainer];

    // RECHTS: Verlauf und Chat
    var rightContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight)];
    [rightContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightContainer setBackgroundColor:[CPColor colorWithWhite:0.95 alpha:1.0]];

    // Untere Eingabeleiste (Höhe 80px)
    var inputContainerHeight = 80.0;
    var chatScrollHeight = splitHeight - inputContainerHeight;
    
    _chatScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, chatScrollHeight)];
    [_chatScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_chatScrollView setAutohidesScrollers:YES];
    [_chatScrollView setHasHorizontalScroller:NO];
    [_chatScrollView setBackgroundColor:[CPColor whiteColor]];

    _chatDocumentView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, chatScrollHeight)];
    [_chatDocumentView setAutoresizingMask:CPViewWidthSizable];
    [_chatScrollView setDocumentView:_chatDocumentView];
    [rightContainer addSubview:_chatScrollView];

    var inputContainer = [[CPView alloc] initWithFrame:CGRectMake(0, chatScrollHeight, rightWidth, inputContainerHeight)];
    [inputContainer setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin];
    [inputContainer setBackgroundColor:[CPColor colorWithWhite:0.92 alpha:1.0]];
    [rightContainer addSubview:inputContainer];

    // Sende-Zeile (Reihe 1)
    _chatInputField = [[CPTextField alloc] initWithFrame:CGRectMake(15, 12, rightWidth - 145, 32)];
    [_chatInputField setAutoresizingMask:CPViewWidthSizable];
    [_chatInputField setEditable:YES];
    [_chatInputField setBezeled:YES];
    [_chatInputField setFont:[CPFont systemFontOfSize:13.0]];
    [_chatInputField setTextColor:[CPColor blackColor]];
    [_chatInputField setPlaceholderString:@"Search emails or ask a question..."];
    [_chatInputField setEnabled:NO];
    [_chatInputField setTarget:self];
    [_chatInputField setAction:@selector(submitChatAction:)];
    [inputContainer addSubview:_chatInputField];

    _chatSendButton = [[CPButton alloc] initWithFrame:CGRectMake(rightWidth - 120, 12, 105, 32)];
    [_chatSendButton setTitle:@"Send"];
    [_chatSendButton setAutoresizingMask:CPViewMinXMargin];
    [_chatSendButton setEnabled:NO];
    [_chatSendButton setTarget:self];
    [_chatSendButton setAction:@selector(submitChatAction:)];
    [inputContainer addSubview:_chatSendButton];

    // Status-Text unten links über volle verbleibende Breite (Reihe 2)
    _statusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 48, rightWidth - 60, 22)];
    [_statusLabel setStringValue:@"Loading mailbox structure..."];
    [_statusLabel setTextColor:[CPColor colorWithWhite:0.3 alpha:1.0]];
    [_statusLabel setFont:[CPFont systemFontOfSize:11.0]];
    [_statusLabel setLineBreakMode:CPLineBreakByWordWrapping];
    [_statusLabel setAutoresizingMask:CPViewWidthSizable];
    [inputContainer addSubview:_statusLabel];

    // Spinning-Indikator dezent unten ganz rechts platziert (Reihe 2)
    _progressBar = [[CPProgressIndicator alloc] initWithFrame:CGRectMake(rightWidth - 40, 48, 20, 20)];
    [_progressBar setStyle:CPProgressIndicatorSpinningStyle];
    [_progressBar setIndeterminate:YES];
    [_progressBar setHidden:YES];
    [_progressBar setAutoresizingMask:CPViewMinXMargin];
    [inputContainer addSubview:_progressBar];

    [splitView addSubview:rightContainer];
    [contentView addSubview:splitView];

    [_mainWindow orderFront:self];
    [self initializeNewSessionOnClient];
    [self fetchMailboxes:nil];
}

// --- TABLE VIEW DATA SOURCE METHODS ---

- (int)numberOfRowsInTableView:(CPTableView)tableView
{
    return [_summaryRows count];
}

- (id)tableView:(CPTableView)tableView objectValueForTableColumn:(CPTableColumn)tableColumn row:(int)row
{
    var rowData = [_summaryRows objectAtIndex:row];
    var ident = [tableColumn identifier];
    return [rowData objectForKey:ident];
}

// --- MAILBOX LOADER ---

- (void)loadMailboxesData:(id)data
{
    [_summaryRows removeAllObjects];
    
    if (data && data.length > 0) {
        for (var i = 0; i < data.length; i++) {
            var box = data[i];
            
            var mailboxName = box.Name || box.name || @"-";
            
            var totalVal = @"0";
            if (box.TotalCount !== undefined) {
                totalVal = box.TotalCount + @"";
            } else if (box.total_count !== undefined) {
                totalVal = box.total_count + @"";
            }
            
            var unreadVal = @"0";
            if (box.UnreadCount !== undefined) {
                unreadVal = box.UnreadCount + @"";
            } else if (box.unread_count !== undefined) {
                unreadVal = box.unread_count + @"";
            }
           
            var rowDict = [CPDictionary dictionaryWithObjectsAndKeys:
                mailboxName, @"name",
                totalVal, @"totalCount",
                unreadVal, @"unreadCount"
            ];
            [_summaryRows addObject:rowDict];
        }
    }
    
    [_summaryTableView reloadData];
}

- (void)fetchMailboxes:(id)sender
{
    [_progressBar setHidden:NO];
    [_progressBar startAnimation:self];
    [_statusLabel setStringValue:@"Refreshing mailboxes..."];

    var selfRef = self;
    var url = [self backendPath:@"/api/mailboxes"];

    fetch(url, { method: 'GET' })
    .then(function(response) {
        if (!response.ok) {
            throw new Error("Failed to load mailbox structure.");
        }
        return response.json();
    })
    .then(function(data) {
        [_progressBar stopAnimation:selfRef];
        [_progressBar setHidden:YES];
        [_statusLabel setStringValue:@"Mailbox structure loaded."];
        [selfRef loadMailboxesData:data];
        
        [_chatInputField setEnabled:YES];
        [_chatInputField setPlaceholderString:@"Search emails or ask a question..."];
        [_chatSendButton setEnabled:YES];
    })
    .catch(function(error) {
        [_progressBar stopAnimation:selfRef];
        [_progressBar setHidden:YES];
        [_statusLabel setStringValue:@"Loading failed."];
        [selfRef appendMessageWithSender:@"bot" text:@"Connection to server failed: " + error.message isError:YES downloads:nil thumbnails:nil saveToHistory:YES];
    });
}

// --- CONFIGURATION SHEET ---

- (void)openSettingsSheet:(id)sender
{
    if (!_settingsWindow)
    {
        _settingsWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 480, 300)
                                                      styleMask:CPTitledWindowMask | CPClosableWindowMask];
        
        var sheetContentView = [_settingsWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        var serviceLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 25, 110, 20)];
        [serviceLabel setStringValue:@"Interface:"];
        [serviceLabel setFont:[CPFont systemFontOfSize:12.0]];
        [serviceLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:serviceLabel];

        _servicePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(135, 22, 180, 26) pullsDown:NO];
        [_servicePopUp addItemWithTitle:@"Ollama (Local)"];
        [[_servicePopUp lastItem] setRepresentedObject:@"ollama"];
        [_servicePopUp addItemWithTitle:@"Groq API"];
        [[_servicePopUp lastItem] setRepresentedObject:@"groq"];
        [_servicePopUp addItemWithTitle:@"Google Gemini"];
        [[_servicePopUp lastItem] setRepresentedObject:@"gemini"];
        [_servicePopUp addItemWithTitle:@"OpenRouter"];
        [[_servicePopUp lastItem] setRepresentedObject:@"openrouter"];
        [_servicePopUp setTarget:self];
        [_servicePopUp setAction:@selector(serviceTypeDidChange:)];
        [sheetContentView addSubview:_servicePopUp];

        var endpointLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 65, 110, 20)];
        [endpointLabel setStringValue:@"Endpoint URL:"];
        [endpointLabel setFont:[CPFont systemFontOfSize:12.0]];
        [endpointLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:endpointLabel];

        _endpointField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 62, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_endpointField setEditable:YES];
        [_endpointField setBezeled:YES];
        [_endpointField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_endpointField];

        var modelLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 105, 110, 20)];
        [modelLabel setStringValue:@"Model Name:"];
        [modelLabel setFont:[CPFont systemFontOfSize:12.0]];
        [modelLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:modelLabel];

        _modelField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 102, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_modelField setEditable:YES];
        [_modelField setBezeled:YES];
        [_modelField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_modelField];

        var apiKeyLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 145, 110, 20)];
        [apiKeyLabel setStringValue:@"API Key:"];
        [apiKeyLabel setFont:[CPFont systemFontOfSize:12.0]];
        [apiKeyLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:apiKeyLabel];

        _apiKeyField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 142, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_apiKeyField setEditable:YES];
        [_apiKeyField setBezeled:YES];
        [_apiKeyField setSecure:YES];
        [_apiKeyField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_apiKeyField];

        var maxStepsLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 185, 110, 20)];
        [maxStepsLabel setStringValue:@"Max Steps:"];
        [maxStepsLabel setFont:[CPFont systemFontOfSize:12.0]];
        [maxStepsLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:maxStepsLabel];

        _maxStepsField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 182, 80, 24)];
        [_maxStepsField setEditable:YES];
        [_maxStepsField setBezeled:YES];
        [_maxStepsField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_maxStepsField];

        var btnY = CGRectGetHeight(sheetBounds) - 45;

        var cancelBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 205, btnY, 90, 26)];
        [cancelBtn setTitle:@"Cancel"];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(closeSettingsSheet:)];
        [sheetContentView addSubview:cancelBtn];

        var saveBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 105, btnY, 90, 26)];
        [saveBtn setTitle:@"Save"];
        [saveBtn setTarget:self];
        [saveBtn setAction:@selector(saveSettings:)];
        [sheetContentView addSubview:saveBtn];
    }

    [_settingsWindow setTitle:@"Interface Settings"];
    
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [defaults objectForKey:@"LLMServiceType"] || @"ollama";

    if (activeService === @"ollama") [_servicePopUp selectItemAtIndex:0];
    else if (activeService === @"groq") [_servicePopUp selectItemAtIndex:1];
    else if (activeService === @"gemini") [_servicePopUp selectItemAtIndex:2];
    else if (activeService === @"openrouter") [_servicePopUp selectItemAtIndex:3];

    [self updateFieldsForService:activeService];

    [_maxStepsField setStringValue:([defaults objectForKey:@"LLMMaxSteps"] || @"5") + @""];

    [CPApp beginSheet:_settingsWindow
        modalForWindow:_mainWindow
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
}

- (void)updateFieldsForService:(CPString)serviceType
{
    var defaults = [CPUserDefaults standardUserDefaults];

    if (serviceType === @"ollama") {
        [_endpointField setEnabled:YES];
        [_endpointField setStringValue:[defaults objectForKey:@"LLMOllamaEndpoint"] || @"http://localhost:11434/api/generate"];
        [_modelField setStringValue:[defaults objectForKey:@"LLMOllamaModel"] || @"gemma4:e4b"];
        [_apiKeyField setEnabled:NO];
        [_apiKeyField setStringValue:@""];
        [_apiKeyField setPlaceholderString:@"Not required"];
    } else {
        [_endpointField setEnabled:NO];
        [_endpointField setStringValue:@""];
        [_endpointField setPlaceholderString:@"Predefined server URL"];
        [_apiKeyField setEnabled:YES];
        [_apiKeyField setPlaceholderString:@"Enter API Key"];
        
        if (serviceType === @"groq") {
            [_modelField setStringValue:[defaults objectForKey:@"LLMGroqModel"] || @"llama-3.1-8b-instant"];
            [_apiKeyField setStringValue:[defaults objectForKey:@"LLMGroqAPIKey"] || @""];
        } else if (serviceType === @"gemini") {
            [_modelField setStringValue:[defaults objectForKey:@"LLMGeminiModel"] || @"gemini-2.5-flash"];
            [_apiKeyField setStringValue:[defaults objectForKey:@"LLMGeminiAPIKey"] || @""];
        } else if (serviceType === @"openrouter") {
            [_modelField setStringValue:[defaults objectForKey:@"LLMOpenRouterModel"] || @"google/gemini-2.0-flash-001"];
            [_apiKeyField setStringValue:[defaults objectForKey:@"LLMOpenRouterAPIKey"] || @""];
        }
    }
}

- (void)serviceTypeDidChange:(id)sender
{
    var newService = [[_servicePopUp selectedItem] representedObject];
    [self updateFieldsForService:newService];
}

- (void)closeSettingsSheet:(id)sender
{
    [CPApp endSheet:_settingsWindow];
    [_settingsWindow orderOut:self];
}

- (void)saveSettings:(id)sender
{
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [[_servicePopUp selectedItem] representedObject] || @"ollama";
    
    [defaults setObject:activeService forKey:@"LLMServiceType"];

    if (activeService === @"ollama") {
        [defaults setObject:[_endpointField stringValue] forKey:@"LLMOllamaEndpoint"];
        [defaults setObject:[_modelField stringValue] forKey:@"LLMOllamaModel"];
    } else if (activeService === @"groq") {
        [defaults setObject:[_modelField stringValue] forKey:@"LLMGroqModel"];
        [defaults setObject:[_apiKeyField stringValue] forKey:@"LLMGroqAPIKey"];
    } else if (activeService === @"gemini") {
        [defaults setObject:[_modelField stringValue] forKey:@"LLMGeminiModel"];
        [defaults setObject:[_apiKeyField stringValue] forKey:@"LLMGeminiAPIKey"];
    } else if (activeService === @"openrouter") {
        [defaults setObject:[_modelField stringValue] forKey:@"LLMOpenRouterModel"];
        [defaults setObject:[_apiKeyField stringValue] forKey:@"LLMOpenRouterAPIKey"];
    }

    var parsedSteps = parseInt([_maxStepsField stringValue]) || 5;
    [defaults setObject:parsedSteps forKey:@"LLMMaxSteps"];

    [self closeSettingsSheet:sender];
    [_statusLabel setStringValue:@"Settings saved."];
}

- (CPDictionary)currentLLMConfigPayload
{
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [defaults objectForKey:@"LLMServiceType"] || @"ollama";
    
    var config = [CPMutableDictionary dictionary];
    [config setObject:activeService forKey:@"service"];
    
    var maxSteps = [defaults objectForKey:@"LLMMaxSteps"] || 5;
    [config setObject:maxSteps forKey:@"max_steps"];

    if (activeService === @"ollama") {
        [config setObject:([defaults objectForKey:@"LLMOllamaEndpoint"] || @"") forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMOllamaModel"] || @"") forKey:@"model"];
        [config setObject:@"" forKey:@"api_key"];
    } else if (activeService === @"groq") {
        [config setObject:@"" forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMGroqModel"] || @"") forKey:@"model"];
        [config setObject:([defaults objectForKey:@"LLMGroqAPIKey"] || @"") forKey:@"api_key"];
    } else if (activeService === @"gemini") {
        [config setObject:@"" forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMGeminiModel"] || @"") forKey:@"model"];
        [config setObject:([defaults objectForKey:@"LLMGeminiAPIKey"] || @"") forKey:@"api_key"];
    } else if (activeService === @"openrouter") {
        [config setObject:@"" forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMOpenRouterModel"] || @"") forKey:@"model"];
        [config setObject:([defaults objectForKey:@"LLMOpenRouterAPIKey"] || @"") forKey:@"api_key"];
    }

    return config;
}

// --- SESSION WORKFLOWS ---

- (void)initializeNewSessionOnClient
{
    var date = new Date().getTime();
    var rand = Math.floor(Math.random() * 1000);
    _currentSessionId = "session_" + date + "_" + rand;

    _currentChatY = 20;
    [_chatMessages removeAllObjects];

    [[_chatDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [_chatDocumentView setFrameSize:CGSizeMake(CGRectGetWidth([_chatScrollView bounds]) - 20, CGRectGetHeight([_chatScrollView bounds]))];
    
    // Aligned welcome text explaining actual capabilities
    var greetingText = @"### Welcome to MailArchivist!\n\n" +
                       "Here is a short **instruction guide** for your email assistant:\n\n" +
                       "• **Mailbox Browsing**: Browse database folders on the left side, showing total indexed and unread counts.\n" +
                       "• **Keyword & Semantic Search**: Ask standard queries or describe concepts (e.g., *“Find discussions about server migrations”*), utilizing PostgreSQL vector embeddings.\n" +
                       "• **Precise Scope**: Activate **“Search selected mailbox only”** below the list to restrict the assistant's perspective.\n" +
                       "• **Direct Actions**: Instruct the assistant to **archive** messages or directly **open** physical emails natively inside macOS Mail.app.\n\n" +
                       "*How can I help you today?*";

    [self appendMessageWithSender:@"bot" text:greetingText isError:NO downloads:nil thumbnails:nil saveToHistory:YES];
}

- (void)newSessionAction:(id)sender
{
    [self initializeNewSessionOnClient];
}

// --- CHAT MANAGEMENT ---

- (void)submitChatAction:(id)sender
{
    var prompt = [_chatInputField stringValue];
    if (!prompt || [prompt stringByTrimmingWhitespace] === @"") {
        return;
    }

    var progressBar = _progressBar,
        selfRef = self,
        chatInputField = _chatInputField,
        chatSendButton = _chatSendButton,
        statusLabel = _statusLabel;

    // Apply selected mailbox constraints to prompt if checkbox is checked
    var payloadPrompt = prompt;
    var selectedRow = [_summaryTableView selectedRow];
    var mailboxFilter = null;
    if (selectedRow !== -1 && [_mailboxConstraintCheckbox state] == CPOnState) {
        var rowData = [_summaryRows objectAtIndex:selectedRow];
        var mailboxName = [rowData objectForKey:@"name"];
        mailboxFilter = { "mailbox": mailboxName };
        payloadPrompt = "[Constraint: Answer this question EXCLUSIVELY with emails from the mailbox '" + mailboxName + "'.] " + prompt;
    }

    [chatInputField setStringValue:@""];
    [chatInputField setEnabled:NO];
    [chatSendButton setEnabled:NO];
    [progressBar setHidden:NO];
    [progressBar startAnimation:selfRef];
    [statusLabel setStringValue:@"Processing query..."];

    [self appendMessageWithSender:@"user" text:prompt isError:NO downloads:nil thumbnails:nil saveToHistory:YES];

    var chatUrl = [self backendPath:@"/api/chat"];
    var configDict = [self currentLLMConfigPayload];
    var configJSObject = {};
    var keys = [configDict allKeys];
    for (var i = 0; i < [keys count]; i++) {
        var k = [keys objectAtIndex:i];
        configJSObject[k] = [configDict objectForKey:k];
    }

    var payload = {
        "session_id": _currentSessionId,
        "prompt": payloadPrompt,
        "llm_config": configJSObject
    };

    if (mailboxFilter) {
        payload["mailbox_filter"] = mailboxFilter;
    }

    fetch(chatUrl, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
    })
    .then(function(response) {
        if (!response.ok) {
            throw new Error("Failed to retrieve resources from server.");
        }
        return response.json();
    })
    .then(function(data) {
        [progressBar stopAnimation:selfRef];
        [progressBar setHidden:YES];
        [chatInputField setEnabled:YES];
        [chatInputField becomeFirstResponder];
        [chatSendButton setEnabled:YES];
        [statusLabel setStringValue:@"Response received."];

        if (data.error || data.success === false)
        {
            var errText = data.error || "Unexpected server error.";
            if (data.details) errText += "\n\nDetails: " + data.details;
            [selfRef appendMessageWithSender:@"bot" text:@"Error:\n" + errText isError:YES downloads:nil thumbnails:nil saveToHistory:YES];
        }
        else
        {
            var msg = data.output || "Action successfully completed.";
            var cpDownloads = data.downloads ? [CPArray arrayWithArray:data.downloads] : nil;
            var cpThumbnails = data.thumbnails ? [CPArray arrayWithArray:data.thumbnails] : nil;
            [selfRef appendMessageWithSender:@"bot" text:msg isError:NO downloads:cpDownloads thumbnails:cpThumbnails saveToHistory:YES];
        }
        [[CPRunLoop currentRunLoop] limitDateForMode:CPDefaultRunLoopMode];
    })
    .catch(function(error) {
        [progressBar stopAnimation:selfRef];
        [progressBar setHidden:YES];
        [chatInputField setEnabled:YES];
        [chatInputField becomeFirstResponder];
        [chatSendButton setEnabled:YES];
        [statusLabel setStringValue:@"Processing error."];
        [selfRef appendMessageWithSender:@"bot" text:@"Communication failed: " + error.message isError:YES downloads:nil thumbnails:nil saveToHistory:YES];
    });
}

// --- UNIFIED IMPORT/EXPORT ---

- (void)openHistorySheet:(id)sender
{
    if (!_historySheetWindow)
    {
        _historySheetWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 580, 460)
                                                   styleMask:CPTitledWindowMask | CPClosableWindowMask | CPResizableWindowMask];
        
        var sheetContentView = [_historySheetWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        var infoLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 10, CGRectGetWidth(sheetBounds) - 30, 45)];
        [infoLabel setStringValue:@"Copy the JSON below to export, or paste an old JSON and click \"Import\"."];
        [infoLabel setFont:[CPFont systemFontOfSize:11.0]];
        [infoLabel setTextColor:[CPColor darkGrayColor]];
        [infoLabel setLineBreakMode:CPLineBreakByWordWrapping];
        [infoLabel setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
        [sheetContentView addSubview:infoLabel];

        var scroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 60, CGRectGetWidth(sheetBounds) - 30, CGRectGetHeight(sheetBounds) - 130)];
        [scroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scroll setAutohidesScrollers:YES];

        _historySheetTextView = [[CPTextView alloc] initWithFrame:[scroll bounds]];
        [_historySheetTextView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [_historySheetTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [_historySheetTextView setRichText:NO];
        [scroll setDocumentView:_historySheetTextView];
        [sheetContentView addSubview:scroll];

        var btnY = CGRectGetHeight(sheetBounds) - 50;

        var cancelBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 235, btnY, 110, 26)];
        [cancelBtn setTitle:@"Close"];
        [cancelBtn setAutoresizingMask:CPViewMinXMargin | CPViewMinYMargin];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(closeHistorySheet:)];
        [sheetContentView addSubview:cancelBtn];

        var actionBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 115, btnY, 100, 26)];
        [actionBtn setTitle:@"Import"];
        [actionBtn setAutoresizingMask:CPViewMinXMargin | CPViewMinYMargin];
        [actionBtn setTarget:self];
        [actionBtn setAction:@selector(executeImportHistoryAction:)];
        [sheetContentView addSubview:actionBtn];
    }

    [_historySheetWindow setTitle:@"Transfer History"];
    
    var serializedArray = [];
    for (var i = 0; i < [_chatMessages count]; i++) {
        var msg = [_chatMessages objectAtIndex:i];
        var jsObj = {
            "sender": msg.sender,
            "text": msg.text,
            "isError": msg.isError,
            "downloads": msg.downloads ? (typeof msg.downloads.array === "function" ? [msg.downloads array] : msg.downloads) : null,
            "thumbnails": msg.thumbnails ? (typeof msg.thumbnails.array === "function" ? [msg.thumbnails array] : msg.thumbnails) : null
        };
        serializedArray.push(jsObj);
    }
    
    var jsonString = JSON.stringify(serializedArray, null, 2);
    [_historySheetTextView setString:jsonString];

    [CPApp beginSheet:_historySheetWindow
        modalForWindow:_mainWindow
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
           
    window.setTimeout(function() { [_historySheetTextView selectAll:self]; }, 100);
}

- (void)closeHistorySheet:(id)sender
{
    [CPApp endSheet:_historySheetWindow];
    [_historySheetWindow orderOut:self];
}

- (void)executeImportHistoryAction:(id)sender
{
    var jsonString = [_historySheetTextView string];
    if (jsonString && [jsonString length] > 0)
    {
        try {
            var parsedArray = JSON.parse(jsonString);
            if (Array.isArray(parsedArray)) {
                [self loadHistoryFromParsedArray:parsedArray];
            } else {
                [_statusLabel setStringValue:@"Error: Invalid JSON format."];
            }
        } catch(e) {
            [_statusLabel setStringValue:@"Error parsing JSON data."];
        }
    }
    [self closeHistorySheet:sender];
}

- (void)loadHistoryFromParsedArray:(id)parsedArray
{
    [_chatMessages removeAllObjects];
    [[_chatDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    _currentChatY = 20;

    for (var i = 0; i < parsedArray.length; i++) {
        var msg = parsedArray[i];
        var cpDownloads = nil;
        if (msg.downloads && msg.downloads.length > 0) {
            cpDownloads = [CPArray arrayWithArray:msg.downloads];
        }
        var cpThumbnails = nil;
        if (msg.thumbnails && msg.thumbnails.length > 0) {
            cpThumbnails = [CPArray arrayWithArray:msg.thumbnails];
        }
        [self appendMessageWithSender:msg.sender 
                                 text:msg.text 
                              isError:msg.isError 
                            downloads:cpDownloads 
                           thumbnails:cpThumbnails
                        saveToHistory:YES];
    }
    [_statusLabel setStringValue:@"History successfully loaded."];
}

// --- DYNAMISCHER CHAT-FEED ---

- (void)appendMessageWithSender:(CPString)sender text:(CPString)text isError:(BOOL)isError downloads:(CPArray)downloads thumbnails:(CPArray)thumbnails saveToHistory:(BOOL)save
{
    if (save) {
        var historyItem = {
            "sender": sender,
            "text": text,
            "isError": isError,
            "downloads": downloads ? [downloads copy] : nil,
            "thumbnails": thumbnails ? [thumbnails copy] : nil
        };
        [_chatMessages addObject:historyItem];
    }

    var docWidth = CGRectGetWidth([_chatScrollView bounds]) - 50;
    var cleanedText = text || @"";

    var textView = [[CPTextView alloc] initWithFrame:CGRectMake(15, 10, docWidth - 30, 20)];
    [textView setEditable:YES];
    [textView setRichText:YES];
    [textView setSelectable:YES];
    [textView setBackgroundColor:[CPColor clearColor]];
    [textView setAutoresizingMask:CPViewWidthSizable];
    
    // Parse Markdown into CPAttributedString
    var parsedAttrStr = [MarkdownParser attributedStringFromMarkdown:cleanedText];
    
    // Setzen der Attributed String direkt im TextStorage
    [textView insertText:parsedAttrStr];
    
    // TableMatrixViews innerhalb des Layouts platzieren
    var length = [parsedAttrStr length];
    var searchRange = CPMakeRange(0, 0);
    var layoutManager = [textView layoutManager];
    var textContainer = [textView textContainer];
    var textViewWidth = CGRectGetWidth([textView bounds]);

    while (searchRange.location < length)
    {
        var attrs = [parsedAttrStr attributesAtIndex:searchRange.location effectiveRange:searchRange];
        var tableAttachment = [attrs objectForKey:@"TableAttachmentAttribute"];
        if (tableAttachment) {
            var rect = [layoutManager boundingRectForGlyphRange:searchRange inTextContainer:textContainer];
            var inset = [textView textContainerInset];
            var totalWidth = textViewWidth - 40; 
            
            if (totalWidth < 100)
                totalWidth = 100;

            rect.origin.x += inset.width;
            rect.origin.y += inset.height;
            rect.size.width = totalWidth;

            [tableAttachment resizeToWidth:totalWidth];
            [tableAttachment setFrame:rect];

            [textView addSubview:tableAttachment];
        }
        searchRange.location = CPMaxRange(searchRange);
    }
    // --------------------------------------------
    
    var usedRect = [layoutManager usedRectForTextContainer:textContainer];
    var textHeight = CGRectGetHeight(usedRect);

    if (textHeight < 20) {
        textHeight = 20;
    }
    
    var cardHeight = (cleanedText.length > 0) ? (textHeight + 20) : 20;
    
    var isUserMsg = [sender isEqualToString:@"user"];
    var fillColor = [CPColor colorWithWhite:0.96 alpha:1.0];
    if (isUserMsg) {
        fillColor = [CPColor colorWithRed:0.90 green:0.93 blue:1.0 alpha:1.0];
    } else if (isError) {
        fillColor = [CPColor colorWithRed:1.0 green:0.90 blue:0.90 alpha:1.0];
    }

    var cardBox = [[SpeechBubbleBox alloc] initWithFrame:CGRectMake(15, _currentChatY, docWidth, cardHeight + 10) 
                                                  isUser:isUserMsg 
                                               fillColor:fillColor];
    [cardBox addSubview:textView];
    [_chatDocumentView addSubview:cardBox];

    _currentChatY += cardHeight + 25; 
    [_chatDocumentView setFrameSize:CGSizeMake(CGRectGetWidth([_chatScrollView bounds]), _currentChatY + 50)];

    var boundsHeight = CGRectGetHeight([_chatScrollView bounds]);
    if (_currentChatY > boundsHeight) {
        [[_chatScrollView contentView] scrollToPoint:CGPointMake(0, _currentChatY - boundsHeight + 80)];
    }
}

- (CPString)backendPath:(CPString)path
{
    if ([BackendBaseURL length] > 0 && [path hasPrefix:@"/"]) {
        return BackendBaseURL + path;
    }
    return BackendBaseURL + path;
}

@end
