// YTInternalIdentity.x
//
// Flip client-side "Googler / internal" nos gates do Phenotype — o equivalente
// do FBTEmployeeMode.x do FBTweak, no formato Logos (%group/%hook), adaptado às
// classes reais do YouTube (validadas por disassembly no exec arm64).
//
// Por que a superfície é pequena (análise exaustiva do exec, não chute):
//   * O YouTube NÃO importa nenhuma função C de gating (varridos 8061 imports;
//     só OpenGL/SwiftUI/Swift stdlib) -> não há camada de fishhook estilo
//     FBTInternalImports (EasyGating). Funções C internas exigiriam inline hook
//     em __TEXT, proibido em sideload.
//   * O YTIInnerTubeContext (proto do contexto InnerTube) não tem campo
//     user/internal/role -> nada pra flipar no request; a identidade é o token
//     da conta autenticada (-[YTAccountScopedInnerTubeServiceImpl
//     performHTTPRequest:withIdentity:] / verifyActiveIdentity:), resolvida
//     server-side.
//   * O YTSettingsExperimentsViewController não tem gate de elegibilidade
//     client-side (só hasDefaultSelection/isSettingsChanged/textFieldShouldReturn:).
//   * Não existe getter isEmployee/isInternalUser em classes YT/GIK/SSO/OGL;
//     "internalUser" é entidade de servidor (TSLSSEInternalUser : GPBMessage).
//   * Flags "internal/dogfood/debug" de config já são cobertas pelo core do
//     YTABConfig (ele hooka todos os getters BOOL de ColdConfig/HotConfig).
//
// Logo, o único NET-NEW client-side é a determinação de conta Googler / build
// interno do Phenotype (PHT), sistema compartilhado do Google que entrega
// flags/experimentos:
//   -[PHTHeterodyneSyncer isGooglerAccount:]           B24@0:8@16 (checa domínio da conta)
//   -[PHTHeterodyneSyncer hasGooglerAccount]           B16@0:8   (itera contas -> isGooglerAccount:)
//   -[PHTHeterodyneSyncer isInternalHeterodyneSyncer]  B16@0:8   (neste build: retorna NO fixo)
//   -[PHTInternalHeterodyneSyncer isInternalHeterodyneSyncer] B16@0:8
//
// Isto flipa a CRENÇA client-side sobre ser Googler/interno (destrava o que for
// gated no cliente pelo Phenotype) — igual o employee-mode do FBTweak, que não
// forja token de servidor. A tela "Search Experiments" puxa dados via InnerTube
// autorizado pela conta real, então pode continuar dando "Erro ao carregar" numa
// conta não-allowlisted. Quem valida no device é o usuário.
//
// Sideload-safe: só ObjC swizzle via Logos %hook (usa MSHookMessageEx por baixo,
// GOT/__DATA, nunca patch em __TEXT).

#import <Foundation/Foundation.h>

static inline BOOL YTABCInternalIdentityOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"YTABCInternalIdentity"];
}

%group YTABCInternalGates

%hook PHTHeterodyneSyncer
- (BOOL)isGooglerAccount:(id)account {
    return YTABCInternalIdentityOn() ? YES : %orig;
}
- (BOOL)hasGooglerAccount {
    return YTABCInternalIdentityOn() ? YES : %orig;
}
- (BOOL)isInternalHeterodyneSyncer {
    return YTABCInternalIdentityOn() ? YES : %orig;
}
%end

%hook PHTInternalHeterodyneSyncer
- (BOOL)isInternalHeterodyneSyncer {
    return YTABCInternalIdentityOn() ? YES : %orig;
}
%end

%end // YTABCInternalGates

// Instala o grupo uma vez. Chamado do launch (Tweak.x, gated por pref) e do
// toggle das settings. O Phenotype é framework core (carregado antes do
// didFinishLaunching), então objc_getClass resolve no %init.
void YTABCInstallInternalIdentityHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init(YTABCInternalGates);
    });
}
