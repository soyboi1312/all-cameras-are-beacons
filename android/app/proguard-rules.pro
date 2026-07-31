# App-specific R8 keep rules. Intentionally empty: JSON parsing is platform org.json (no
# reflection-based serialization or DI anywhere in app/src), every component (activity, FGS,
# widget receiver, QS tile service, FileProvider) is manifest-registered and auto-kept, and
# osmdroid 6.1.20 needs no keeps. Add rules here only when release smoke-testing surfaces a
# real breakage, not preemptively.
