#if FROM_CC_INFO != 1 || TRANSITIVE != 1
#error Missing propagated defines
#endif
#if OVERRIDE != 2
#error User flags must follow toolchain-expanded defines
#endif
#ifdef REMOVE_ME
#error User flags must be able to undefine a propagated define
#endif
#ifdef PRIVATE
#error Local defines must not propagate to bindgen
#endif

struct BindgenActionTest { int value; };
