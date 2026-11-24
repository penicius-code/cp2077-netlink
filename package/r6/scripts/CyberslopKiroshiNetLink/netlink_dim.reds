// Cyberslop Kiroshi NetLink 1.3.0 - screen dimmer (2026-11-04)
// A uniform dark grade over the whole picture, toggled and set from the NetLink CET window.
//
// It rides DigitalVixenCore's grading service (dvcore_grading.reds), the same path True Sunglasses uses:
// DVCore pulls up to four layers and multiplies their gain into the live ColorGradingAreaSettings.
// DVCore's third slot reads DVGP_GradeLayer.Current() when a module named "DVGradeProbe" exists
// (DVCore's own debug probe, not installed here). This file declares that module, so the dimmer stacks
// with True Sunglasses (slot 0) without editing DVCore or TS. If the real DVGradeProbe is ever
// installed, remove one of the two (duplicate class names).
//
// CET side: Game.GetScriptableSystemsContainer():Get('DVGradeProbe.DVGP_State'):Set(on, darkness)

module DVGradeProbe
import DigitalVixenCore.*

public class DVGP_State extends ScriptableSystem {
  private let m_on: Bool;
  private let m_dark: Float;

  public func Set(on: Bool, dark: Float) -> Void {
    this.m_on = on;
    this.m_dark = ClampF(dark, 0.0, 0.95);
    DVGrading.Refresh();
  }

  public func IsOn() -> Bool = this.m_on;
  public func Darkness() -> Float = this.m_dark;

  public static func Get() -> ref<DVGP_State> {
    return GameInstance.GetScriptableSystemsContainer(GetGameInstance()).Get(n"DVGradeProbe.DVGP_State") as DVGP_State;
  }
}

public abstract class DVGP_GradeLayer {
  public static func Current() -> ref<DVGradeLayer> {
    let sys: ref<DVGP_State> = DVGP_State.Get();
    if !IsDefined(sys) || sys.Darkness() <= 0.0 { return DVGrading.Neutral(); }
    let L: ref<DVGradeLayer> = new DVGradeLayer();
    let g: Float = 1.0 - sys.Darkness();
    L.gainR = g;
    L.gainG = g;
    L.gainB = g;
    // Off keeps the gain and only drops the target, so DVCore fades it out instead of cutting.
    L.target = sys.IsOn() ? 1.0 : 0.0;
    L.fadeSeconds = 0.35;
    return L;
  }
}
