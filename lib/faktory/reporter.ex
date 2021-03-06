defmodule Faktory.Reporter do
  @moduledoc false

  defstruct [:config, :conn]

  alias Faktory.{Utils, Logger}

  def start_link(config) do
    Task.start_link(__MODULE__, :run, [config])
  end

  def run(config) do
    {:ok, conn} = Faktory.Connection.start_link(config)
    report_queue = Faktory.Registry.name(config.module, :report_queue)

    Stream.repeatedly(fn -> BlockingQueue.pop(report_queue) end)
    |> Enum.each(&report(conn, &1))
  end

  defp report(conn, result) do
    case result do
      {:ack, jid} -> ack(conn, jid)
      {:fail, jid, info} -> fail(conn, jid, info)
    end
  end

  defp ack(conn, jid, errors \\ 0) do
    case Faktory.Protocol.ack(conn, jid) do
      {:ok, jid} -> log_success(:ack, %{jid: jid})
      {:error, reason} ->
        log_and_sleep(:ack, reason, errors)
        ack(conn, jid, errors + 1) # Retry
    end
  end

  defp fail(conn, jid, info, errors \\ 0) do
    errtype = info.errtype
    message = info.message
    trace   = info.trace

    case Faktory.Protocol.fail(conn, jid, errtype, message, trace) do
      {:ok, jid} -> log_success(:fail, %{jid: jid, error: info})
      {:error, reason} ->
        log_and_sleep(:fail, reason, errors)
        fail(conn, jid, info, errors + 1) # Retry
    end
  end

  defp log_success(op, data) do
    import Utils, only: [if_test: 1]
    Logger.debug("#{op} success: #{data.jid}")
    if_test do: send TestJidPidMap.get(data.jid), {op, data}
  end

  defp log_and_sleep(op, reason, errors) do
    reason = Utils.stringify(reason)
    sleep_time = Utils.exp_backoff(errors)
    Logger.warn("#{op} failure: #{reason} -- retrying in #{sleep_time/1000}s")
    Process.sleep(sleep_time)
  end

end
