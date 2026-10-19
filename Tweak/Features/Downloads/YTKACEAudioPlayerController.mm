#import "YTKACEAudioPlayerController.h"
#import "../../YTKACE.h"
#import "YTKACEDownloadPlayerController.h"
#import "MediaArtwork.h"
#import "DownloadSponsor.h"
#import "../../Settings/YTKACESettingsPages.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>

static void YTKACEStyleAudioSlider(UISlider *slider) {
    UIImage *fill = [YTKACEProgressFillImage(240.0, 4.0) resizableImageWithCapInsets:UIEdgeInsetsZero
                                                                         resizingMode:UIImageResizingModeStretch];
    [slider setMinimumTrackImage:fill forState:UIControlStateNormal];
    UIColor *tint = YTKACEProgressScrubberTint();
    for (NSNumber *size in @[@14.0, @22.0]) {
        CGFloat diameter = size.doubleValue;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
            initWithSize:CGSizeMake(diameter, diameter)];
        UIImage *thumb = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            [tint setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.0, 0.0, diameter, diameter)] fill];
        }];
        [slider setThumbImage:thumb forState:diameter < 20.0 ? UIControlStateNormal : UIControlStateHighlighted];
    }
}

static NSString *YTKACEAudioTime(NSTimeInterval value) {
    if (!isfinite(value) || value < 0.0) return @"0:00";
    NSInteger seconds = (NSInteger)floor(value);
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)(seconds / 60), (long)(seconds % 60)];
}

static NSCache *YTKACEQueueInfoCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 400;
    });
    return cache;
}

static void YTKACELoadQueueInfo(NSURL *URL, void (^completion)(NSDictionary *info)) {
    static NSMutableDictionary<NSString *, NSMutableArray *> *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    NSString *key = URL.path;
    NSMutableArray *waiting = pending[key];
    if (waiting != nil) {
        [waiting addObject:[completion copy]];
        return;
    }
    pending[key] = [NSMutableArray arrayWithObject:[completion copy]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        // The row thumbnail is 44 pt; decode a small, aspect-fill-safe size instead of full size.
        UIImage *artwork = YTKACEMediaArtworkImageWithMaxPixelSize(URL, 256.0);
        if (artwork != nil && artwork.size.width > 0.0 && artwork.size.height > 0.0) {
            CGFloat side = 44.0;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                initWithSize:CGSizeMake(side, side)];
            info[@"thumb"] = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                CGSize size = artwork.size;
                CGFloat scale = MAX(side / size.width, side / size.height);
                CGSize drawn = CGSizeMake(size.width * scale, size.height * scale);
                [artwork drawInRect:CGRectMake((side - drawn.width) * 0.5, (side - drawn.height) * 0.5,
                                               drawn.width, drawn.height)];
            }];
        }
        NSTimeInterval duration = CMTimeGetSeconds([AVURLAsset URLAssetWithURL:URL options:nil].duration);
        info[@"duration"] = @(isfinite(duration) && duration > 0.0 ? duration : 0.0);
        NSString *channel = YTKACEStoredChannelName(URL);
        if (channel.length != 0) info[@"channel"] = channel;
        dispatch_async(dispatch_get_main_queue(), ^{
            [YTKACEQueueInfoCache() setObject:info forKey:key];
            NSArray *callbacks = pending[key];
            [pending removeObjectForKey:key];
            for (void (^callback)(NSDictionary *) in callbacks) callback(info);
        });
    });
}

@interface YTKACEQueueCell : UITableViewCell
@property(nonatomic, strong) UIImageView *thumb;
@property(nonatomic, strong) UILabel *title;
@property(nonatomic, strong) UILabel *detail;
@property(nonatomic, strong) UIImageView *playing;
@property(nonatomic, copy) NSURL *URL;
@end

@implementation YTKACEQueueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self != nil) {
        self.backgroundColor = UIColor.clearColor;
        self.thumb = [UIImageView new];
        self.thumb.contentMode = UIViewContentModeScaleAspectFill;
        self.thumb.clipsToBounds = YES;
        self.thumb.layer.cornerRadius = 6.0;
        self.thumb.tintColor = UIColor.systemGrayColor;
        self.title = [UILabel new];
        self.title.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        self.detail = [UILabel new];
        self.detail.font = [UIFont systemFontOfSize:12.0];
        self.detail.textColor = UIColor.secondaryLabelColor;
        self.playing = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"]];
        self.playing.contentMode = UIViewContentModeScaleAspectFit;
        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[self.title, self.detail]];
        labels.axis = UILayoutConstraintAxisVertical;
        labels.spacing = 2.0;
        for (UIView *view in @[self.thumb, labels, self.playing]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [self.thumb.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
            [self.thumb.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.thumb.widthAnchor constraintEqualToConstant:44.0],
            [self.thumb.heightAnchor constraintEqualToConstant:44.0],
            [labels.leadingAnchor constraintEqualToAnchor:self.thumb.trailingAnchor constant:12.0],
            [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.playing.leadingAnchor constraintEqualToAnchor:labels.trailingAnchor constant:8.0],
            [self.playing.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6.0],
            [self.playing.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.playing.widthAnchor constraintEqualToConstant:18.0]
        ]];
    }
    return self;
}

@end

@interface YTKACEAudioPlayerController ()
    <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) YTKACEDownloadPlaybackSession *session;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) UILabel *positionLabel;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *channelLabel;
@property(nonatomic, strong) UILabel *elapsedLabel;
@property(nonatomic, strong) UILabel *durationLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *repeatButton;
@property(nonatomic, strong) UIView *topBar;
@property(nonatomic, strong) UIView *controlsView;
@property(nonatomic, strong) UIView *queuePanel;
@property(nonatomic, strong) UIView *queueHeader;
@property(nonatomic, strong) UIView *grabber;
@property(nonatomic, strong) UILabel *queueTitle;
@property(nonatomic, strong) UILabel *queueSubtitle;
@property(nonatomic, strong) UIView *miniRow;
@property(nonatomic, strong) NSLayoutConstraint *miniHeight;
@property(nonatomic, strong) UIImageView *miniArtwork;
@property(nonatomic, strong) UILabel *miniTitle;
@property(nonatomic, strong) UILabel *miniChannel;
@property(nonatomic, strong) UIButton *miniPlay;
@property(nonatomic, strong) UITableView *queueTable;
@property(nonatomic, strong) NSLayoutConstraint *queueHeight;
@property(nonatomic, assign) NSInteger queueState;
@property(nonatomic, assign) BOOL draggingQueue;
@property(nonatomic, assign) BOOL tableDrivesQueue;
@property(nonatomic, assign) BOOL tablePanIgnored;
@property(nonatomic, assign) CGFloat dragStartHeight;
@property(nonatomic, assign) CGFloat dragBaseline;
@property(nonatomic, strong) UIView *optionsView;
@property(nonatomic, strong) UIView *optionsCard;
@property(nonatomic, strong) UILabel *speedDetail;
@property(nonatomic, strong) UILabel *sleepDetail;
@property(nonatomic, strong) UILabel *autoplayDetail;
@property(nonatomic, strong) NSTimer *sleepTimer;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, assign) BOOL scrubbing;
@property(nonatomic, assign) NSInteger sleepMinutes;
@property(nonatomic, copy) NSURL *artworkURL;
@property(nonatomic, copy) NSURL *channelURL;
@property(nonatomic, copy) NSString *channelName;
@end

@implementation YTKACEAudioPlayerController

- (void)applyTheme {
    self.view.backgroundColor =
        YTKACEInterfaceBackgroundColor(self.traitCollection);
    self.queuePanel.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.miniArtwork.backgroundColor =
        YTKACEInterfaceBackgroundColor(self.traitCollection);
    self.optionsCard.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.artworkView.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.titleLabel.textColor = UIColor.labelColor;
    self.channelLabel.textColor = UIColor.secondaryLabelColor;
    self.positionLabel.textColor = UIColor.secondaryLabelColor;
    self.elapsedLabel.textColor = UIColor.secondaryLabelColor;
    self.durationLabel.textColor = UIColor.secondaryLabelColor;
    YTKACEStyleAudioSlider(self.slider);
    self.slider.maximumTrackTintColor = UIColor.tertiaryLabelColor;
    self.playButton.tintColor = UIColor.labelColor;
    [self.queueTable reloadData];
}

- (instancetype)initWithSession:(YTKACEDownloadPlaybackSession *)session {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        self.session = session;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildPlayer];
    [self buildQueue];
    [self buildOptions];
    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadPlaybackDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadInfoChanged:)
        name:YTKACEDownloadInfoDidChangeNotification object:nil];
    __weak YTKACEAudioPlayerController *weakSelf = self;
    self.timeObserver = [self.session.player addPeriodicTimeObserverForInterval:
        CMTimeMakeWithSeconds(0.5, 600) queue:dispatch_get_main_queue()
        usingBlock:^(__unused CMTime time) { [weakSelf refreshTime]; }];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme];
    [self.session play];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection == nil ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self applyTheme];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.sleepTimer invalidate];
    if (self.timeObserver != nil) {
        [self.session.player removeTimeObserver:self.timeObserver];
    }
}

- (BOOL)prefersStatusBarHidden { return NO; }

- (UIButton *)symbolButton:(NSString *)symbol size:(CGFloat)size action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
            weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
        forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)timeLabel {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedDigitSystemFontOfSize:11.0
        weight:UIFontWeightRegular];
    label.textColor = UIColor.secondaryLabelColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildPlayer {
    UIButton *minimize = [self symbolButton:@"chevron.down" size:17.0
        action:@selector(minimize)];
    UIButton *more = [self symbolButton:@"ellipsis" size:21.0
        action:@selector(showOptions)];
    self.positionLabel = [UILabel new];
    self.positionLabel.textAlignment = NSTextAlignmentCenter;
    self.positionLabel.textColor = UIColor.secondaryLabelColor;
    self.positionLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        minimize, self.positionLabel, more
    ]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [minimize.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [minimize.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [more.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [more.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [self.view addSubview:top];
    self.topBar = top;

    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 9.0;
    self.artworkView.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.artworkView];

    self.titleLabel = [UILabel new];
    self.titleLabel.textColor = UIColor.labelColor;
    self.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];
    self.channelLabel = [UILabel new];
    self.channelLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    self.channelLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.channelLabel];

    self.slider = [UISlider new];
    YTKACEStyleAudioSlider(self.slider);
    self.slider.maximumTrackTintColor = UIColor.tertiaryLabelColor;
    self.slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.slider addTarget:self action:@selector(sliderStarted)
        forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sliderChanged)
        forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderEnded)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
            UIControlEventTouchCancel];
    [self.view addSubview:self.slider];
    self.elapsedLabel = [self timeLabel];
    self.durationLabel = [self timeLabel];
    self.durationLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.elapsedLabel];
    [self.view addSubview:self.durationLabel];

    self.repeatButton = [self symbolButton:@"repeat" size:19.0
        action:@selector(toggleRepeat)];
    UIButton *previous = [self symbolButton:@"backward.end.fill" size:19.0
        action:@selector(previous)];
    self.playButton = [self symbolButton:@"pause.fill" size:44.0
        action:@selector(togglePlayback)];
    UIButton *next = [self symbolButton:@"forward.end.fill" size:19.0
        action:@selector(next)];
    UIButton *shuffle = [self symbolButton:@"shuffle" size:19.0
        action:@selector(shuffleQueue)];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.repeatButton, previous, self.playButton, next, shuffle
    ]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.distribution = UIStackViewDistributionEqualSpacing;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *button in @[self.repeatButton, previous, next, shuffle]) {
        [button.widthAnchor constraintEqualToConstant:44.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:44.0].active = YES;
    }
    [self.playButton.widthAnchor constraintEqualToConstant:72.0].active = YES;
    [self.playButton.heightAnchor constraintEqualToConstant:72.0].active = YES;
    [self.view addSubview:controls];
    self.controlsView = controls;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *artworkWidth = [self.artworkView.widthAnchor
        constraintEqualToAnchor:self.view.widthAnchor multiplier:0.78];
    artworkWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4.0],
        [top.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [top.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [top.heightAnchor constraintEqualToConstant:44.0],
        [self.artworkView.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:12.0],
        [self.artworkView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        artworkWidth,
        [self.artworkView.widthAnchor constraintLessThanOrEqualToConstant:410.0],
        [self.artworkView.heightAnchor constraintEqualToAnchor:self.artworkView.widthAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor constant:16.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20.0],
        [self.channelLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2.0],
        [self.channelLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.channelLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.slider.topAnchor constraintEqualToAnchor:self.channelLabel.bottomAnchor constant:10.0],
        [self.slider.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.slider.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.elapsedLabel.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:-2.0],
        [self.elapsedLabel.leadingAnchor constraintEqualToAnchor:self.slider.leadingAnchor],
        [self.durationLabel.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:-2.0],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:self.slider.trailingAnchor],
        [controls.topAnchor constraintEqualToAnchor:self.elapsedLabel.bottomAnchor constant:16.0],
        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:26.0],
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-26.0],
        [controls.heightAnchor constraintEqualToConstant:76.0]
    ]];
}

- (void)buildQueue {
    self.queuePanel = [UIView new];
    self.queuePanel.layer.cornerRadius = 16.0;
    self.queuePanel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.queuePanel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.queuePanel.layer.shadowOpacity = 0.16;
    self.queuePanel.layer.shadowRadius = 14.0;
    self.queuePanel.layer.shadowOffset = CGSizeMake(0.0, -2.0);
    self.queuePanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.queuePanel];

    UIView *content = [UIView new];
    content.clipsToBounds = YES;
    content.layer.cornerRadius = 16.0;
    content.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queuePanel addSubview:content];

    self.queueHeader = [UIView new];
    self.queueHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queueHeader addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleQueue)]];
    [self.queueHeader addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(headerPanned:)]];
    [content addSubview:self.queueHeader];

    self.grabber = [UIView new];
    self.grabber.backgroundColor = UIColor.tertiaryLabelColor;
    self.grabber.layer.cornerRadius = 2.5;
    self.grabber.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queueHeader addSubview:self.grabber];

    self.queueTitle = [UILabel new];
    self.queueTitle.text = YTKACELocalized(@"Your Queue");
    self.queueTitle.textColor = UIColor.labelColor;
    self.queueTitle.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.queueSubtitle = [UILabel new];
    self.queueSubtitle.textColor = UIColor.secondaryLabelColor;
    self.queueSubtitle.font = [UIFont systemFontOfSize:12.0];
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.queueTitle, self.queueSubtitle
    ]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 1.0;
    titles.userInteractionEnabled = NO;
    titles.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queueHeader addSubview:titles];

    self.miniRow = [UIView new];
    self.miniRow.clipsToBounds = YES;
    self.miniRow.alpha = 0.0;
    self.miniRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.miniRow addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(collapseQueue)]];
    [content addSubview:self.miniRow];
    self.miniArtwork = [UIImageView new];
    self.miniArtwork.contentMode = UIViewContentModeScaleAspectFill;
    self.miniArtwork.clipsToBounds = YES;
    self.miniArtwork.layer.cornerRadius = 6.0;
    self.miniArtwork.tintColor = UIColor.systemGrayColor;
    self.miniTitle = [UILabel new];
    self.miniTitle.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.miniTitle.textColor = UIColor.labelColor;
    self.miniChannel = [UILabel new];
    self.miniChannel.font = [UIFont systemFontOfSize:12.0];
    self.miniChannel.textColor = UIColor.secondaryLabelColor;
    UIStackView *miniLabels = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.miniTitle, self.miniChannel
    ]];
    miniLabels.axis = UILayoutConstraintAxisVertical;
    miniLabels.spacing = 1.0;
    self.miniPlay = [self symbolButton:@"pause.fill" size:20.0 action:@selector(togglePlayback)];
    UIButton *miniNext = [self symbolButton:@"forward.end.fill" size:17.0 action:@selector(next)];
    for (UIView *view in @[self.miniArtwork, miniLabels, self.miniPlay, miniNext]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.miniRow addSubview:view];
    }

    self.queueTable = [[UITableView alloc] initWithFrame:CGRectZero
        style:UITableViewStylePlain];
    self.queueTable.backgroundColor = UIColor.clearColor;
    self.queueTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.queueTable.rowHeight = 60.0;
    self.queueTable.dataSource = self;
    self.queueTable.delegate = self;
    self.queueTable.allowsSelectionDuringEditing = YES;
    self.queueTable.showsVerticalScrollIndicator = NO;
    self.queueTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queueTable registerClass:YTKACEQueueCell.class forCellReuseIdentifier:@"YTKACEAudioQueueCell"];
    [self.queueTable setEditing:YES animated:NO];
    [self.queueTable.panGestureRecognizer addTarget:self action:@selector(tablePanned:)];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(queuePressed:)];
    [self.queueTable addGestureRecognizer:press];
    [content addSubview:self.queueTable];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.queueHeight = [self.queuePanel.heightAnchor constraintEqualToConstant:60.0];
    self.miniHeight = [self.miniRow.heightAnchor constraintEqualToConstant:0.0];
    [NSLayoutConstraint activateConstraints:@[
        [self.queuePanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.queuePanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.queuePanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.queueHeight,
        [content.topAnchor constraintEqualToAnchor:self.queuePanel.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:self.queuePanel.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.queuePanel.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.queuePanel.bottomAnchor],
        [self.queueHeader.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.queueHeader.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.queueHeader.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.queueHeader.heightAnchor constraintEqualToConstant:56.0],
        [self.grabber.topAnchor constraintEqualToAnchor:self.queueHeader.topAnchor constant:6.0],
        [self.grabber.centerXAnchor constraintEqualToAnchor:self.queueHeader.centerXAnchor],
        [self.grabber.widthAnchor constraintEqualToConstant:36.0],
        [self.grabber.heightAnchor constraintEqualToConstant:5.0],
        [titles.leadingAnchor constraintEqualToAnchor:self.queueHeader.leadingAnchor constant:20.0],
        [titles.trailingAnchor constraintLessThanOrEqualToAnchor:self.queueHeader.trailingAnchor constant:-20.0],
        [titles.centerYAnchor constraintEqualToAnchor:self.queueHeader.centerYAnchor constant:4.0],
        [self.miniRow.topAnchor constraintEqualToAnchor:self.queueHeader.bottomAnchor],
        [self.miniRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.miniRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        self.miniHeight,
        [self.miniArtwork.leadingAnchor constraintEqualToAnchor:self.miniRow.leadingAnchor constant:16.0],
        [self.miniArtwork.topAnchor constraintEqualToAnchor:self.miniRow.topAnchor constant:4.0],
        [self.miniArtwork.widthAnchor constraintEqualToConstant:48.0],
        [self.miniArtwork.heightAnchor constraintEqualToConstant:48.0],
        [miniLabels.leadingAnchor constraintEqualToAnchor:self.miniArtwork.trailingAnchor constant:12.0],
        [miniLabels.centerYAnchor constraintEqualToAnchor:self.miniArtwork.centerYAnchor],
        [miniLabels.trailingAnchor constraintLessThanOrEqualToAnchor:self.miniPlay.leadingAnchor constant:-8.0],
        [self.miniPlay.centerYAnchor constraintEqualToAnchor:self.miniArtwork.centerYAnchor],
        [self.miniPlay.widthAnchor constraintEqualToConstant:44.0],
        [self.miniPlay.heightAnchor constraintEqualToConstant:44.0],
        [miniNext.leadingAnchor constraintEqualToAnchor:self.miniPlay.trailingAnchor],
        [miniNext.trailingAnchor constraintEqualToAnchor:self.miniRow.trailingAnchor constant:-8.0],
        [miniNext.centerYAnchor constraintEqualToAnchor:self.miniArtwork.centerYAnchor],
        [miniNext.widthAnchor constraintEqualToConstant:44.0],
        [miniNext.heightAnchor constraintEqualToConstant:44.0],
        [self.queueTable.topAnchor constraintEqualToAnchor:self.miniRow.bottomAnchor],
        [self.queueTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.queueTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.queueTable.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
}

- (UIView *)optionRow:(NSString *)symbol title:(NSString *)title
                detail:(UILabel **)detail action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.labelColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0
            weight:UIImageSymbolWeightRegular];
    UIImage *image = [UIImage systemImageNamed:symbol
                             withConfiguration:configuration];
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.tintColor = UIColor.labelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = UIColor.labelColor;
    name.font = [UIFont systemFontOfSize:15.0];
    UILabel *value = [UILabel new];
    value.textColor = UIColor.secondaryLabelColor;
    value.font = [UIFont systemFontOfSize:15.0];
    value.textAlignment = NSTextAlignmentRight;
    value.lineBreakMode = NSLineBreakByTruncatingTail;
    if (detail != NULL) *detail = value;
    UIView *spacer = [UIView new];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon, name, spacer, value
    ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 14.0;
    row.alignment = UIStackViewAlignmentCenter;
    row.userInteractionEnabled = NO;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:26.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:26.0].active = YES;
    [name setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                          forAxis:UILayoutConstraintAxisHorizontal];
    [value setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisHorizontal];
    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:15.0],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-15.0],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor]
    ]];
    return button;
}

- (void)buildOptions {
    self.optionsView = [UIView new];
    self.optionsView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    self.optionsView.hidden = YES;
    self.optionsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.optionsView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideOptions)];
    tap.delegate = self;
    [self.optionsView addGestureRecognizer:tap];

    self.optionsCard = [UIView new];
    self.optionsCard.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.optionsCard.layer.cornerRadius = 12.0;
    self.optionsCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.optionsView addSubview:self.optionsCard];
    UILabel *handle = [UILabel new];
    handle.text = YTKACELocalized(@"━");
    handle.textColor = UIColor.tertiaryLabelColor;
    handle.textAlignment = NSTextAlignmentCenter;
    handle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.optionsCard addSubview:handle];
    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.distribution = UIStackViewDistributionFillEqually;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *speedDetail = nil;
    UILabel *sleepDetail = nil;
    UILabel *autoplayDetail = nil;
    [rows addArrangedSubview:[self optionRow:@"speedometer"
        title:@"Playback Speed" detail:&speedDetail action:@selector(selectSpeed)]];
    [rows addArrangedSubview:[self optionRow:@"moon.zzz.fill"
        title:@"Sleep Timer" detail:&sleepDetail action:@selector(selectSleep)]];
    [rows addArrangedSubview:[self optionRow:@"forward.end.fill"
        title:@"AutoPlay" detail:&autoplayDetail action:@selector(toggleAutoplay)]];
    self.speedDetail = speedDetail;
    self.sleepDetail = sleepDetail;
    self.autoplayDetail = autoplayDetail;
    [rows addArrangedSubview:[self optionRow:@"list.bullet"
        title:@"Play Next" detail:NULL action:@selector(next)]];
    [rows addArrangedSubview:[self optionRow:@"xmark"
        title:@"Close" detail:NULL action:@selector(hideOptions)]];
    [self.optionsCard addSubview:rows];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.optionsView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.optionsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.optionsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.optionsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.optionsCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:7.0],
        [self.optionsCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-7.0],
        [self.optionsCard.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-7.0],
        [self.optionsCard.heightAnchor constraintEqualToConstant:286.0],
        [handle.topAnchor constraintEqualToAnchor:self.optionsCard.topAnchor constant:2.0],
        [handle.centerXAnchor constraintEqualToAnchor:self.optionsCard.centerXAnchor],
        [handle.heightAnchor constraintEqualToConstant:20.0],
        [rows.topAnchor constraintEqualToAnchor:handle.bottomAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:self.optionsCard.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:self.optionsCard.trailingAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:self.optionsCard.bottomAnchor constant:-5.0]
    ]];
}

- (void)playbackChanged:(NSNotification *)notification {
    (void)notification;
    [self refresh];
}

- (void)downloadInfoChanged:(NSNotification *)notification {
    NSURL *URL = notification.object;
    if (![URL isKindOfClass:NSURL.class] || [URL.path isEqualToString:self.channelURL.path]) {
        self.channelURL = nil;
    }
    if ([URL isKindOfClass:NSURL.class]) [YTKACEQueueInfoCache() removeObjectForKey:URL.path];
    [self refresh];
}

- (void)refresh {
    NSURL *URL = self.session.currentURL;
    self.titleLabel.text = URL.lastPathComponent.stringByDeletingPathExtension ?: @"Audio";
    // Reading the channel means an xattr read + JSON parse; refresh runs on every playback
    // change, so only re-read it when the track changes or its info was rewritten.
    if (URL == nil || ![URL isEqual:self.channelURL]) {
        self.channelURL = URL;
        self.channelName = URL == nil ? nil : YTKACEStoredChannelName(URL);
    }
    self.channelLabel.text = self.channelName;
    if (![URL isEqual:self.artworkURL]) {
        self.artworkURL = URL;
        UIImage *artwork = URL == nil ? nil : YTKACEMediaArtworkImage(URL);
        self.artworkView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
        self.miniArtwork.image = self.artworkView.image;
    }
    self.artworkView.tintColor = UIColor.systemGrayColor;
    self.miniTitle.text = self.titleLabel.text;
    self.miniChannel.text = self.channelLabel.text;
    NSInteger nextIndex = self.session.currentIndex == NSNotFound ? NSNotFound : self.session.currentIndex + 1;
    NSArray<NSURL *> *playlist = self.session.playlist;
    self.queueSubtitle.text = nextIndex != NSNotFound && nextIndex < (NSInteger)playlist.count
        ? playlist[(NSUInteger)nextIndex].lastPathComponent.stringByDeletingPathExtension
        : [NSString stringWithFormat:@"%lu", (unsigned long)playlist.count];
    NSInteger count = self.session.playlist.count;
    NSInteger index = self.session.currentIndex == NSNotFound
        ? 0 : self.session.currentIndex + 1;
    self.positionLabel.text = [NSString stringWithFormat:@"%ld / %ld",
        (long)index, (long)count];
    NSString *play = self.session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self.playButton setImage:[UIImage systemImageNamed:play] forState:UIControlStateNormal];
    [self.miniPlay setImage:[UIImage systemImageNamed:play] forState:UIControlStateNormal];
    self.repeatButton.tintColor = self.session.repeatEnabled
        ? UIColor.systemRedColor : UIColor.labelColor;
    self.speedDetail.text = [NSString stringWithFormat:@"· %.2gx",
        self.session.playbackRate];
    if (self.session.pauseAtEnd) {
        self.sleepDetail.text = YTKACELocalized(@"· End of track");
    } else if (self.sleepTimer.isValid) {
        self.sleepDetail.text = [NSString stringWithFormat:@"· %ldm",
            (long)self.sleepMinutes];
    } else {
        self.sleepDetail.text = YTKACELocalized(@"· Off");
    }
    self.autoplayDetail.text = self.session.autoplayEnabled ? @"· On" : @"· Off";
    [self.queueTable reloadData];
    [self refreshTime];
}

- (void)refreshTime {
    NSTimeInterval current = CMTimeGetSeconds(self.session.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(self.session.player.currentItem.duration);
    if (!isfinite(current)) current = 0.0;
    if (!isfinite(duration) || duration < 0.0) duration = 0.0;
    if (!self.scrubbing) {
        self.slider.maximumValue = MAX(duration, 1.0);
        self.slider.value = MIN(current, self.slider.maximumValue);
    }
    self.elapsedLabel.text = YTKACEAudioTime(current);
    self.durationLabel.text = YTKACEAudioTime(duration);
}

- (void)togglePlayback { [self.session togglePlayback]; [self refresh]; }
- (void)previous { [self.session playPrevious]; [self refresh]; }
- (void)next { [self.session playNext]; [self hideOptions]; [self refresh]; }
- (void)toggleRepeat { self.session.repeatEnabled = !self.session.repeatEnabled; [self refresh]; }

- (void)sliderStarted { self.scrubbing = YES; }
- (void)sliderChanged { self.elapsedLabel.text = YTKACEAudioTime(self.slider.value); }
- (void)sliderEnded {
    self.scrubbing = NO;
    [self.session.player seekToTime:CMTimeMakeWithSeconds(self.slider.value, 600)
        toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (CGFloat)queueHeightForState:(NSInteger)state {
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGFloat collapsed = 60.0 + self.view.safeAreaInsets.bottom;
    CGFloat full = MAX(height - CGRectGetMaxY(self.topBar.frame) - 6.0, collapsed);
    if (state <= 0) return collapsed;
    if (state >= 2) return full;
    CGFloat below = height - CGRectGetMaxY(self.controlsView.frame) - 8.0;
    CGFloat half = below >= 220.0 ? below : height * 0.46;
    return MIN(MAX(half, collapsed + 80.0), full);
}

- (void)updateQueueProgress {
    CGFloat collapsed = [self queueHeightForState:0];
    CGFloat half = [self queueHeightForState:1];
    CGFloat full = [self queueHeightForState:2];
    CGFloat height = self.queueHeight.constant;
    CGFloat expand = full - half > 1.0 ? (height - half) / (full - half) : 0.0;
    expand = MIN(MAX(expand, 0.0), 1.0);
    CGFloat peek = half - collapsed > 1.0 ? (half - height) / (half - collapsed) : 1.0;
    peek = MIN(MAX(peek, 0.0), 1.0);
    self.miniHeight.constant = 60.0 * expand;
    self.miniRow.alpha = expand;
    self.queueSubtitle.alpha = peek;
}

- (void)setQueueState:(NSInteger)state velocity:(CGFloat)velocity {
    self.queueState = MIN(MAX(state, 0), 2);
    self.queueHeight.constant = [self queueHeightForState:self.queueState];
    self.queueTable.showsVerticalScrollIndicator = self.queueState == 2;
    [self updateQueueProgress];
    CGFloat distance = fabs(self.queuePanel.bounds.size.height - self.queueHeight.constant);
    CGFloat spring = distance > 1.0 ? MIN(fabs(velocity) / distance, 8.0) : 0.0;
    [UIView animateWithDuration:0.42 delay:0.0 usingSpringWithDamping:0.86
        initialSpringVelocity:spring options:UIViewAnimationOptionAllowUserInteraction |
            UIViewAnimationOptionBeginFromCurrentState
        animations:^{ [self.view layoutIfNeeded]; } completion:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.draggingQueue) return;
    CGFloat target = [self queueHeightForState:self.queueState];
    if (fabs(target - self.queueHeight.constant) > 0.5) {
        self.queueHeight.constant = target;
        [self updateQueueProgress];
    }
}

- (void)toggleQueue {
    [self setQueueState:self.queueState == 0 ? 1 : 0 velocity:0.0];
}

- (void)collapseQueue {
    [self setQueueState:0 velocity:0.0];
}

- (void)dragQueueTo:(CGFloat)translation {
    CGFloat low = [self queueHeightForState:0];
    CGFloat high = [self queueHeightForState:2];
    CGFloat height = self.dragStartHeight - translation;
    if (height > high) height = high + (height - high) * 0.2;
    if (height < low) height = low - (low - height) * 0.2;
    self.queueHeight.constant = height;
    [self updateQueueProgress];
}

- (void)finishQueueDrag:(CGFloat)velocity {
    self.draggingQueue = NO;
    CGFloat projected = self.queueHeight.constant - velocity * 0.18;
    NSInteger best = 0;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSInteger state = 0; state <= 2; state++) {
        CGFloat distance = fabs([self queueHeightForState:state] - projected);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = state;
        }
    }
    [self setQueueState:best velocity:velocity];
}

- (void)headerPanned:(UIPanGestureRecognizer *)pan {
    CGFloat translation = [pan translationInView:self.view].y;
    if (pan.state == UIGestureRecognizerStateBegan) {
        [self.queuePanel.layer removeAllAnimations];
        self.draggingQueue = YES;
        self.dragStartHeight = self.queuePanel.bounds.size.height;
        self.queueHeight.constant = self.dragStartHeight;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        [self dragQueueTo:translation];
    } else if (pan.state != UIGestureRecognizerStatePossible) {
        [self finishQueueDrag:[pan velocityInView:self.view].y];
    }
}

- (void)tablePanned:(UIPanGestureRecognizer *)pan {
    UITableView *table = self.queueTable;
    CGFloat top = -table.adjustedContentInset.top;
    CGFloat translation = [pan translationInView:self.view].y;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.tableDrivesQueue = NO;
        self.tablePanIgnored = NO;
        self.dragBaseline = translation;
        UIView *hit = [table hitTest:[pan locationInView:table] withEvent:nil];
        for (UIView *view = hit; view != nil && view != table; view = view.superview) {
            if ([NSStringFromClass(view.class) containsString:@"Reorder"]) {
                self.tablePanIgnored = YES;
                break;
            }
        }
    }
    if (self.tablePanIgnored) return;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        if (!self.tableDrivesQueue) {
            BOOL atTop = table.contentOffset.y <= top + 0.5;
            BOOL pullingDown = translation > self.dragBaseline;
            if (self.queueState != 2 || (atTop && pullingDown)) {
                self.tableDrivesQueue = YES;
                self.draggingQueue = YES;
                self.dragBaseline = translation;
                self.dragStartHeight = self.queuePanel.bounds.size.height;
            } else {
                self.dragBaseline = MIN(self.dragBaseline, translation);
                return;
            }
        }
        [self dragQueueTo:translation - self.dragBaseline];
        table.contentOffset = CGPointMake(table.contentOffset.x, top);
        return;
    }
    if (self.tableDrivesQueue && pan.state != UIGestureRecognizerStatePossible) {
        self.tableDrivesQueue = NO;
        [self finishQueueDrag:[pan velocityInView:self.view].y];
        table.contentOffset = CGPointMake(table.contentOffset.x, top);
    }
}

- (void)queuePressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.queueTable indexPathForRowAtPoint:[press locationInView:self.queueTable]];
    NSArray<NSURL *> *playlist = self.session.playlist;
    if (path == nil || (NSUInteger)path.row >= playlist.count) return;
    NSURL *URL = playlist[(NSUInteger)path.row];
    if ([URL isEqual:self.session.currentURL]) return;
    __weak YTKACEAudioPlayerController *weakSelf = self;
    dispatch_block_t playNext = ^{
        YTKACEAudioPlayerController *strongSelf = weakSelf;
        NSMutableArray<NSURL *> *queue = [strongSelf.session.playlist mutableCopy];
        if (![queue containsObject:URL]) return;
        [queue removeObject:URL];
        NSUInteger current = strongSelf.session.currentURL == nil
            ? NSNotFound : [queue indexOfObject:strongSelf.session.currentURL];
        [queue insertObject:URL atIndex:current == NSNotFound ? 0 : current + 1];
        [strongSelf.session updatePlaylist:queue];
        [strongSelf refresh];
    };
    dispatch_block_t remove = ^{
        YTKACEAudioPlayerController *strongSelf = weakSelf;
        NSMutableArray<NSURL *> *queue = [strongSelf.session.playlist mutableCopy];
        [queue removeObject:URL];
        [strongSelf.session updatePlaylist:queue];
        [strongSelf refresh];
    };
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightRegular];
    YTKACEPresentNativeSheet(URL.lastPathComponent.stringByDeletingPathExtension, nil,
        [self.queueTable cellForRowAtIndexPath:path] ?: self.queueTable, @[
        @{@"title": YTKACELocalized(@"Play Next"),
          @"icon": [UIImage systemImageNamed:@"text.line.first.and.arrowtriangle.forward"
                            withConfiguration:configuration] ?: [UIImage new],
          @"handler": playNext},
        @{@"title": YTKACELocalized(@"Remove"),
          @"icon": [UIImage systemImageNamed:@"trash" withConfiguration:configuration] ?: [UIImage new],
          @"handler": remove}
    ]);
}

- (void)shuffleQueue {
    NSMutableArray<NSURL *> *queue = [self.session.playlist mutableCopy];
    for (NSInteger index = (NSInteger)queue.count - 1; index > 0; index--) {
        [queue exchangeObjectAtIndex:(NSUInteger)index
            withObjectAtIndex:(NSUInteger)arc4random_uniform((uint32_t)index + 1)];
    }
    [self.session updatePlaylist:queue];
    [self refresh];
}

- (void)showOptions {
    [self refresh];
    self.optionsView.hidden = NO;
    self.optionsView.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ self.optionsView.alpha = 1.0; }];
}

- (void)hideOptions {
    if (self.optionsView.hidden) return;
    [UIView animateWithDuration:0.18 animations:^{ self.optionsView.alpha = 0.0; }
        completion:^(__unused BOOL finished) { self.optionsView.hidden = YES; }];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    return gestureRecognizer.view != self.optionsView ||
        ![touch.view isDescendantOfView:self.optionsCard];
}

- (void)selectSpeed {
    NSArray<NSNumber *> *speeds = @[
        @0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75,
        @2.0, @2.5, @3.0, @4.0, @5.0
    ];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSUInteger selected = 0;
    for (NSUInteger index = 0; index < speeds.count; index++) {
        NSNumber *speed = speeds[index];
        [titles addObject:[NSString stringWithFormat:@"%.2gx", speed.floatValue]];
        if (fabs(speed.floatValue - self.session.playbackRate) < 0.01) {
            selected = index;
        }
    }
    YTKACEPresentSelectionMenu(self, self.optionsCard, @"Playback Speed", titles,
        selected, ^(NSUInteger index) {
            self.session.playbackRate = speeds[index].floatValue;
            [self refresh];
        });
}

- (void)selectSleep {
    NSArray<NSString *> *titles = @[
        @"Off", @"End of track", @"15 Minutes", @"30 Minutes",
        @"45 Minutes", @"60 Minutes"
    ];
    NSArray<NSNumber *> *minutes = @[@0, @0, @15, @30, @45, @60];
    NSUInteger selected = self.session.pauseAtEnd ? 1 : 0;
    if (self.sleepTimer.isValid) {
        NSUInteger match = [minutes indexOfObject:@(self.sleepMinutes)];
        if (match != NSNotFound) selected = match;
    }
    YTKACEPresentSelectionMenu(self, self.optionsCard, @"Sleep Timer", titles,
        selected, ^(NSUInteger index) {
            [self.sleepTimer invalidate];
            self.sleepTimer = nil;
            self.sleepMinutes = 0;
            self.session.pauseAtEnd = index == 1;
            NSInteger minute = minutes[index].integerValue;
            if (minute > 0) {
                self.sleepMinutes = minute;
                self.sleepTimer = [NSTimer scheduledTimerWithTimeInterval:
                    minute * 60.0 target:self selector:@selector(sleepFired)
                    userInfo:nil repeats:NO];
            }
            [self refresh];
        });
}

- (void)sleepFired {
    self.sleepMinutes = 0;
    self.sleepTimer = nil;
    [self.session pause];
    [self refresh];
}

- (void)toggleAutoplay {
    self.session.autoplayEnabled = !self.session.autoplayEnabled;
    [self refresh];
}

- (void)minimize {
    dispatch_block_t handler = self.minimizeHandler;
    [self dismissViewControllerAnimated:YES completion:handler];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.session.playlist.count;
}

- (void)fillQueueCell:(YTKACEQueueCell *)cell info:(NSDictionary *)info {
    UIImage *thumb = info[@"thumb"];
    cell.thumb.image = thumb ?: [UIImage systemImageNamed:@"music.note"];
    if (info == nil) {
        cell.detail.text = @" ";
        return;
    }
    NSString *time = YTKACEAudioTime([info[@"duration"] doubleValue]);
    NSString *channel = info[@"channel"];
    cell.detail.text = channel.length != 0 ? [NSString stringWithFormat:@"%@  ·  %@", channel, time] : time;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTKACEQueueCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YTKACEAudioQueueCell"
                                                            forIndexPath:indexPath];
    NSURL *URL = self.session.playlist[(NSUInteger)indexPath.row];
    BOOL current = [URL isEqual:self.session.currentURL];
    UIColor *accent = YTKACEProgressScrubberTint();
    cell.URL = URL;
    cell.title.text = URL.lastPathComponent.stringByDeletingPathExtension;
    cell.title.textColor = current ? accent : UIColor.labelColor;
    cell.playing.hidden = !current;
    cell.playing.tintColor = accent;
    cell.thumb.backgroundColor = YTKACEInterfaceBackgroundColor(self.traitCollection);
    NSDictionary *info = [YTKACEQueueInfoCache() objectForKey:URL.path];
    [self fillQueueCell:cell info:info];
    if (info == nil) {
        __weak YTKACEQueueCell *weakCell = cell;
        __weak YTKACEAudioPlayerController *weakSelf = self;
        YTKACELoadQueueInfo(URL, ^(NSDictionary *loaded) {
            if (![weakCell.URL isEqual:URL]) return;
            [weakSelf fillQueueCell:weakCell info:loaded];
        });
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= self.session.playlist.count) return;
    NSURL *URL = self.session.playlist[(NSUInteger)indexPath.row];
    [self.session loadURL:URL playlist:self.session.playlist index:indexPath.row];
    [self refresh];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
    editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return NO;
}

- (void)tableView:(UITableView *)tableView
    moveRowAtIndexPath:(NSIndexPath *)source
           toIndexPath:(NSIndexPath *)destination {
    (void)tableView;
    NSMutableArray<NSURL *> *queue = [self.session.playlist mutableCopy];
    if ((NSUInteger)source.row >= queue.count || (NSUInteger)destination.row >= queue.count) {
        [self refresh];
        return;
    }
    NSURL *URL = queue[(NSUInteger)source.row];
    [queue removeObjectAtIndex:(NSUInteger)source.row];
    [queue insertObject:URL atIndex:(NSUInteger)destination.row];
    [self.session updatePlaylist:queue];
    [self refresh];
}

@end
