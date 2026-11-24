// Cyberslop Kiroshi NetLink 1.7.1 (2026-11-23)
// Native transform binding for the NetLink device entity, called from the CET mod (init.lua, nativeBind /
// nativeUnbind). EntityGameInterface.BindToComponent is the engine call vanilla EntityAttachementComponent uses
// to hang one entity on a component of another; the bound entity then moves with that component inside the
// engine, with no per-frame teleport from script (a teleport lands a frame late: the device trailed a driving
// car).
// component = name of a placed component of target (NetLink: V's "slots", the body root).
// keepWorld = true (what vanilla passes, and what NetLink passes since 1.7.1): the entity stays where it is
// and rides along from there.
// keepWorld = false: the entity's old world coordinates are kept as its offset from the component (seen in
// game with 1.7.0: device 3239 m from the camera it was bound to). Not useful for a spawned entity.

public static func CyberslopNetLinkBind(child: ref<Entity>, target: ref<Entity>, component: CName, keepWorld: Bool) -> Bool {
  if !IsDefined(child) || !IsDefined(target) || !IsNameValid(component) {
    return false;
  };
  EntityGameInterface.BindToComponent(child.GetEntity(), target.GetEntity(), component, n"None", keepWorld);
  return true;
}

public static func CyberslopNetLinkUnbind(child: ref<Entity>) -> Bool {
  if !IsDefined(child) {
    return false;
  };
  EntityGameInterface.UnbindTransform(child.GetEntity());
  return true;
}
