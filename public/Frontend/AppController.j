// AppController.j
// Cappuccino Frontend for LLMDataAnalyst2 - Email Archive Assistant
// (c) 2026 by Daniel Böhringer

@import <AppKit/AppKit.j>
@import <Foundation/CPObject.j>

var BackendBaseURL = @"";

// --- HELPER CLASS: MARKDOWN -> CPATTRIBUTEDSTRING PARSER ---
@implementation MarkdownParser : CPObject

+ (CPAttributedString)attributedStringFromMarkdown:(CPString)markdown
{
    if (!markdown) {
        return [[CPAttributedString alloc] initWithString:@""];
    }

    var result = [[CPMutableAttributedString alloc] initWithString:@""];
    var lines = markdown.split(/\r?\n/);
    
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var isHeader = false;
        var headerLevel = 0;
        
        // Match headers (# Header)
        var headerMatch = line.match(/^(#{1,6})\s+(.*)$/);
        if (headerMatch) {
            headerLevel = headerMatch[1].length;
            line = headerMatch[2];
            isHeader = true;
        }
        
        // Match list items (- item)
        var isListItem = false;
        var listMatch = line.match(/^(\*|-)\s+(.*)$/);
        if (listMatch) {
            line = "  • " + listMatch[2];
            isListItem = true;
        }
        
        // Parse inline formatting
        var parsedLine = [self parseInlineMarkdown:line isHeader:isHeader headerLevel:headerLevel];
        [result appendAttributedString:parsedLine];
        
        if (i < lines.length - 1) {
            [result appendAttributedString:[[CPAttributedString alloc] initWithString:@"\n"]];
        }
    }
    
    return result;
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
        // Check for Bold-Italic (***)
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
        // Check for Bold (**)
        if (i + 1 < len && text.substr(i, 2) === "**") {
            if (currentSegment.length > 0) {
                [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
                currentSegment = "";
            }
            isBold = !isBold;
            i += 2;
            continue;
        }
        // Check for Italic (*)
        if (text.charAt(i) === "*") {
            if (currentSegment.length > 0) {
                [result appendAttributedString:[self attributedStringWithText:currentSegment font:defaultFont bold:isBold italic:isItalic code:NO]];
                currentSegment = "";
            }
            isItalic = !isItalic;
            i++;
            continue;
        }
        // Check for Monospace/Code (`)
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
    CPTextField         _maxStepsField; // Neu deklariert für Max Steps

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
        @"5" // Default Max Steps
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

    // 2. Actions Menu
    var actionsMenuItem = [mainMenu insertItemWithTitle:@"Actions" action:nil keyEquivalent:nil atIndex:1];
    var actionsMenu = [[CPMenu alloc] initWithTitle:@"Actions"];
    [actionsMenu addItemWithTitle:@"Refresh Mailboxes" action:@selector(fetchMailboxes:) keyEquivalent:@"r"];
    [mainMenu setSubmenu:actionsMenu forItem:actionsMenuItem];

    // 3. Edit Menu
    var editMenuItem = [mainMenu insertItemWithTitle:@"Edit" action:nil keyEquivalent:nil atIndex:2];
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

    // ScrollView füllt fast den gesamten linken Container (außer den Footer für die Checkbox)
    _summaryScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight - 45)];
    [_summaryScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_summaryScrollView setAutohidesScrollers:YES];

    _summaryTableView = [[UploadDropTableView alloc] initWithFrame:[_summaryScrollView bounds]];
    [_summaryTableView setUsesAlternatingRowBackgroundColors:YES];
    [_summaryTableView setCornerView:nil];
    [_summaryTableView setDataSource:self];

    var colAccount = [[CPTableColumn alloc] initWithIdentifier:@"account"];
    [[colAccount headerView] setStringValue:@"Account"];
    [colAccount setWidth:80];
    [colAccount setMinWidth:40];
    [_summaryTableView addTableColumn:colAccount];

    var colMailbox = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[colMailbox headerView] setStringValue:@"Mailbox"];
    [colMailbox setWidth:110];
    [colMailbox setMinWidth:50];
    [_summaryTableView addTableColumn:colMailbox];

    var colUnread = [[CPTableColumn alloc] initWithIdentifier:@"unreadCount"];
    [[colUnread headerView] setStringValue:@"Unread"];
    [colUnread setWidth:leftWidth - 210];
    [colUnread setMinWidth:40];
    [_summaryTableView addTableColumn:colUnread];

    // Gesamtspalte (TotalCount) entfernt, da von Mail.app AppleScript nicht zuverlässig geliefert

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
            
            var accountName = box.Account || box.account || @"-";
            var mailboxName = box.Name || box.name || @"-";
            
            var unreadVal = @"0";
            if (box.UnreadCount !== undefined) {
                unreadVal = box.UnreadCount + @"";
            } else if (box.unreadCount !== undefined) {
                unreadVal = box.unreadCount + @"";
            }
            
            var rowDict = [CPDictionary dictionaryWithObjectsAndKeys:
                accountName, @"account",
                mailboxName, @"name",
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
        // Höhe auf 300 erhöht, um Platz für das "Max Steps" Feld zu schaffen
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

        // NEUES ELEMENT: Max Steps Field
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

    // Max Steps Wert setzen
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

    // Max Steps speichern
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
    
    // Max Steps zum Payload hinzufügen
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
    
    // Englische Kurzanleitung im Markdown-Format
    var greetingText = @"### Welcome to MailArchivist!\n\n" +
                       "Here is a short **instruction guide** for your email assistant:\n\n" +
                       "• **Mailbox Selection**: Select a mailbox in the left sidebar (e.g., `INBOX`).\n" +
                       "• **Search & Query**: Ask questions about your emails (e.g., *“When did the latest email from Quora arrive?”*).\n" +
                       "• **Precise Scope**: Activate **“Search selected mailbox only”** below the list to restrict the assistant's context.\n" +
                       "• **Perform Actions**: Instruct the assistant to archive emails, mark them as read, or draft new responses.\n\n" +
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
        var accountName = [rowData objectForKey:@"account"];
        var mailboxName = [rowData objectForKey:@"name"];
        mailboxFilter = { "account": accountName, "mailbox": mailboxName };
        payloadPrompt = "[Constraint: Answer this question EXCLUSIVELY with emails from the account '" + accountName + "' and the mailbox '" + mailboxName + "'.] " + prompt;
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
    
    // Berechnung der präzisen Texthöhe mittels des integrierten CPLayoutManagers
    var layoutManager = [textView layoutManager],
        textContainer = [textView textContainer];
        
    [layoutManager glyphRangeForTextContainer:textContainer];
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
