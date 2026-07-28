// YTInternalIdentity.x
//
// Flip client-side "Googler / internal" identity gates in YouTube — o
// equivalente do FBTEmployeeMode.x do FBTweak, adaptado para as classes reais
// do YouTube (validadas por disassembly no exec arm64, não por nome).
//
// Onde ficam os gates de identidade interna no YouTube (NÃO em classes YT*):
// o YouTube usa o Phenotype (PHT) do Google — sistema compartilhado de entrega
// de flags/experimentos — para determinar conta Googler / build interno:
//   -[PHTHeterodyneSyncer isGooglerAccount:]          B24@0:8@16
//        (checa o domínio da conta client-side; retorna BOOL)
//   -[PHTHeterodyneSyncer hasGooglerAccount]          B16@0:8
//        (itera contas chamando isGooglerAccount:)
//   -[PHTHeterodyneSyncer isInternalHeterodyneSyncer] B16@0:8
//        (neste build: mov w0,#0; ret  -> retorna NO fixo)
//   -[PHTInternalHeterodyneSyncer isInternalHeterodyneSyncer] B16@0:8
//
// IMPORTANTE (sem delírio): isto flipa a CRENÇA client-side do app sobre ser
// Googler/interno, o que destrava comportamento/flags internas gated no cliente
// pelo Phenotype — igual o employee-mode do FBTweak destrava features internas
// do Facebook. NÃO forja token no servidor. A tela "Search Experiments" puxa os
// dados via InnerTube, que autoriza pela IDENTIDADE DA CONTA autenticada
// (-[YTAccountScopedInnerTubeServiceImpl performHTTPRequest:withIdentity:] /
// verifyActiveIdentity:), resolvida server-side pelo token — não há campo
// "internal" no proto do contexto pra flipar. Então essa tela específica pode
// continuar dando "Erro ao carregar" numa conta não-allowlisted. Quem valida o
// resultado no device é o usuário.
//
// Sideload-safe: só ObjC swizzle (MSHookMessageEx), com verificação de ABI
// antes de hookar (não faz inline hook em __TEXT). Idempotente.
//
// O OGLAccount isGoogleAccount (OneGoogle) NÃO é hookado por padrão: é amplo
// demais (usado em toda a UI de conta) e forçar YES pra qualquer conta pode
// quebrar o account switcher. Fácil de adicionar depois se necessário.

#import <objc/runtime.h>
#import <string.h>
#import <Foundation/Foundation.h>

static inline BOOL YTABCInternalIdentityOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"YTABCInternalIdentity"];
}

typedef BOOL (*YTABCBoolVoidFn)(id, SEL);
typedef BOOL (*YTABCBoolObjFn)(id, SEL, id);

static YTABCBoolObjFn  orig_isGooglerAccount   = NULL;
static YTABCBoolVoidFn orig_hasGooglerAccount  = NULL;
static YTABCBoolVoidFn orig_isInternalSyncer   = NULL;
static YTABCBoolVoidFn orig_isInternalSyncer2  = NULL;

static BOOL ytabc_isGooglerAccount(id self, SEL _cmd, id account) {
    if (YTABCInternalIdentityOn()) return YES;
    return orig_isGooglerAccount ? orig_isGooglerAccount(self, _cmd, account) : NO;
}
static BOOL ytabc_hasGooglerAccount(id self, SEL _cmd) {
    if (YTABCInternalIdentityOn()) return YES;
    return orig_hasGooglerAccount ? orig_hasGooglerAccount(self, _cmd) : NO;
}
static BOOL ytabc_isInternalSyncer(id self, SEL _cmd) {
    if (YTABCInternalIdentityOn()) return YES;
    return orig_isInternalSyncer ? orig_isInternalSyncer(self, _cmd) : NO;
}
static BOOL ytabc_isInternalSyncer2(id self, SEL _cmd) {
    if (YTABCInternalIdentityOn()) return YES;
    return orig_isInternalSyncer2 ? orig_isInternalSyncer2(self, _cmd) : NO;
}

// Só hooka se a assinatura ObjC bater exatamente (BOOL, aridade certa).
static BOOL YTABCEncMatches(Class cls, SEL sel, const char *enc) {
    Method mth = cls ? class_getInstanceMethod(cls, sel) : NULL;
    const char *actual = mth ? method_getTypeEncoding(mth) : NULL;
    return actual && enc && strcmp(actual, enc) == 0;
}
static void YTABCHookBoolVoid(Class cls, const char *name, IMP rep, IMP *orig) {
    if (!cls || !name || !rep || !orig || *orig) return;
    SEL sel = sel_registerName(name);
    if (!YTABCEncMatches(cls, sel, "B16@0:8") && !YTABCEncMatches(cls, sel, "c16@0:8")) return;
    MSHookMessageEx(cls, sel, rep, orig);
}
static void YTABCHookBoolObj(Class cls, const char *name, IMP rep, IMP *orig) {
    if (!cls || !name || !rep || !orig || *orig) return;
    SEL sel = sel_registerName(name);
    if (!YTABCEncMatches(cls, sel, "B24@0:8@16") && !YTABCEncMatches(cls, sel, "c24@0:8@16")) return;
    MSHookMessageEx(cls, sel, rep, orig);
}

// Idempotente. Chamável do launch (Tweak.x) e do toggle (aplica ao vivo pras
// classes já carregadas; o resto pega no próximo launch).
void YTABCInstallInternalIdentityHooks(void) {
    Class pht = objc_getClass("PHTHeterodyneSyncer");
    YTABCHookBoolObj(pht,  "isGooglerAccount:",           (IMP)ytabc_isGooglerAccount,  (IMP *)&orig_isGooglerAccount);
    YTABCHookBoolVoid(pht, "hasGooglerAccount",           (IMP)ytabc_hasGooglerAccount, (IMP *)&orig_hasGooglerAccount);
    YTABCHookBoolVoid(pht, "isInternalHeterodyneSyncer",  (IMP)ytabc_isInternalSyncer,  (IMP *)&orig_isInternalSyncer);
    YTABCHookBoolVoid(objc_getClass("PHTInternalHeterodyneSyncer"),
                      "isInternalHeterodyneSyncer",       (IMP)ytabc_isInternalSyncer2, (IMP *)&orig_isInternalSyncer2);
}
