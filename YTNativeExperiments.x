// YTNativeExperiments.x
//
// Força a abertura da tela nativa de experiment "studies" do YouTube
// (YTSettingsExperimentsTopViewController). Essa tela existe compilada no app
// mas está ÓRFÃ: o único ponteiro pro class object é o registro obrigatório em
// __objc_classlist — não há classref, superref, NSClassFromString nem qualquer
// call site que a instancie. O ponto de entrada nativo foi stripado/gated do
// build público, então não dá pra "chegar" nela; a gente instancia na mão.
//
// Como o app constrói essa VC (validado no binário arm64):
//   O único init é -[YTSettingsExperimentsViewController initWithParentResponder:],
//   que repassa o responder pra [super initWithParentResponder:] (YTResponder /
//   YTStyledViewController). Serviços (YTExperimentsService = YTExperimentsServiceImpl,
//   YTUserDefaults, ...) são resolvidos a partir dessa responder chain, não por
//   parâmetro. YTSettingsViewController e YTSettingsExperimentsViewController
//   compartilham a mesma base (YTStyledViewController) e o mesmo contexto de
//   responder, então o -parentResponder do settings VC que dispara a ação é a
//   fonte de dependência viva e correta pra enfiar no init. Os dois launchers
//   abaixo constroem a VC do mesmo jeito; mudam só na APRESENTAÇÃO.
//
// Duas versões (o usuário testa qual funciona melhor):
//   1. YTABCPushNativeExperiments  -> push na própria nav do settings VC
//      (jeito nativo do YT pra sub-tela de settings; [settingsVC pushViewController:]).
//   2. YTABCPresentNativeExperiments -> estilo FBTweak (fbt_openNativeInternalSettings):
//      embrulha numa UINavigationController nova, adiciona botão Done (a VC nativa
//      não traz um) e apresenta modal (pageSheet) a partir do topMostController
//      real (via connectedScenes).
//
// Nada disso é hook: é chamada direta sob ação do usuário.
//
// Observação: a tela é InnerTube server-driven; em conta sem elegibilidade ela
// vem vazia. Isso é esperado — quem valida o resultado é o usuário, não este
// arquivo.

#import <UIKit/UIKit.h>

// Seletores messageados dinamicamente. Declarados em NSObject pra o ARC aceitar
// sem hard-link contra classes do app; a resolução é toda em runtime.
@interface NSObject (YTABCNativeExperiments)
- (instancetype)initWithParentResponder:(id)parentResponder;
- (id)parentResponder;
- (void)pushViewController:(UIViewController *)viewController;
@end

// Botão Done da VC apresentada modal.
@interface UINavigationController (YTABCNativeExperiments)
- (void)ytabc_dismissNativeExperiments;
@end

@implementation UINavigationController (YTABCNativeExperiments)
- (void)ytabc_dismissNativeExperiments {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// Janela ativa via connectedScenes (mesmo padrão do FBTUtils do FBTweak).
static UIWindow *YTABCActiveKeyWindow(void) {
    UIWindow *key = nil;
    NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in scenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
        if (ws.windows.count) key = ws.windows.firstObject;
    }
    return key;
}

// Sobe a cadeia presented/nav/tab até o controller realmente no topo.
static UIViewController *YTABCTopMostController(void) {
    UIViewController *top = YTABCActiveKeyWindow().rootViewController;
    while (true) {
        if (top.presentedViewController) {
            top = top.presentedViewController;
        } else if ([top isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)top;
            if (nav.topViewController) top = nav.topViewController; else break;
        } else if ([top isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)top;
            if (tab.selectedViewController) top = tab.selectedViewController; else break;
        } else {
            break;
        }
    }
    return top;
}

// Constrói a VC nativa injetando o parentResponder vivo do settings VC.
// Retorna nil (com log) se algo faltar. Compartilhado pelos dois launchers.
static UIViewController *YTABCMakeExperimentsVC(id settingsViewController) {
    Class experimentsClass = NSClassFromString(@"YTSettingsExperimentsTopViewController");
    if (!experimentsClass) {
        NSLog(@"[YTABConfig NativeExp] YTSettingsExperimentsTopViewController ausente neste build");
        return nil;
    }

    // Contexto de responder vivo (resolve YTExperimentsService, YTUserDefaults, ...).
    id parentResponder = nil;
    if ([settingsViewController respondsToSelector:@selector(parentResponder)]) {
        parentResponder = [settingsViewController parentResponder];
    }
    if (!parentResponder) parentResponder = settingsViewController; // ainda está na chain
    if (!parentResponder) {
        NSLog(@"[YTABConfig NativeExp] sem parentResponder vivo pra injetar");
        return nil;
    }

    UIViewController *experimentsVC = nil;
    @try {
        id alloced = [experimentsClass alloc];
        if (![alloced respondsToSelector:@selector(initWithParentResponder:)]) {
            NSLog(@"[YTABConfig NativeExp] initWithParentResponder: indisponível");
            return nil;
        }
        experimentsVC = [alloced initWithParentResponder:parentResponder];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig NativeExp] exceção ao instanciar: %@", exception.reason);
        return nil;
    }
    if (![experimentsVC isKindOfClass:[UIViewController class]]) {
        NSLog(@"[YTABConfig NativeExp] init não retornou UIViewController");
        return nil;
    }
    return experimentsVC;
}

// ---------------------------------------------------------------------------
// Versão 1: push na própria navigation do settings VC (jeito nativo do YT).
// ---------------------------------------------------------------------------
BOOL YTABCPushNativeExperiments(id settingsViewController) {
    UIViewController *experimentsVC = YTABCMakeExperimentsVC(settingsViewController);
    if (!experimentsVC) return NO;

    if (![settingsViewController respondsToSelector:@selector(pushViewController:)]) {
        NSLog(@"[YTABConfig NativeExp] settings VC não responde pushViewController:");
        return NO;
    }
    @try {
        [settingsViewController pushViewController:experimentsVC];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig NativeExp] falha no push: %@", exception.reason);
        return NO;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Versão 2: estilo FBTweak — modal numa nav nova, com botão Done, a partir do
// topMostController real.
// ---------------------------------------------------------------------------
BOOL YTABCPresentNativeExperiments(id settingsViewController) {
    UIViewController *experimentsVC = YTABCMakeExperimentsVC(settingsViewController);
    if (!experimentsVC) return NO;

    UIViewController *presenter = YTABCTopMostController();
    if (!presenter) {
        NSLog(@"[YTABConfig NativeExp] sem presenter no topo");
        return NO;
    }

    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:experimentsVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[ [UISheetPresentationControllerDetent mediumDetent],
                               [UISheetPresentationControllerDetent largeDetent] ];
            sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
            sheet.prefersGrabberVisible = YES;
            sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
        }
    }

    // A VC nativa não traz botão de fechar; adiciona um.
    UIBarButtonItem *close =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:nav
                                                      action:@selector(ytabc_dismissNativeExperiments)];
    if (!experimentsVC.navigationItem.leftBarButtonItem) {
        experimentsVC.navigationItem.leftBarButtonItem = close;
    } else {
        experimentsVC.navigationItem.rightBarButtonItem = close;
    }

    @try {
        [presenter presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *exception) {
        NSLog(@"[YTABConfig NativeExp] falha ao apresentar: %@", exception.reason);
        return NO;
    }
    return YES;
}
