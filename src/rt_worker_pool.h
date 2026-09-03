#pragma once

namespace NAMRig {

class RealtimeJobDispatcher;

// One process-wide pool is shared by all rig instances in a host. Publishing
// is bounded and real-time safe; a saturated/unavailable pool returns false so
// the caller can execute the job synchronously.
RealtimeJobDispatcher* sharedRealtimeJobDispatcher() noexcept;

}  // namespace NAMRig
