ExUnit.start()

# Two tests stage a failed rename with a read-only directory, which root is not subject to:
# as root they would see the move succeed and fail for a reason that is not a defect.
root? =
  case System.find_executable("id") && System.cmd("id", ["-u"]) do
    {uid, 0} -> String.trim(uid) == "0"
    _no_answer -> false
  end

if root?, do: ExUnit.configure(exclude: [:unprivileged])
