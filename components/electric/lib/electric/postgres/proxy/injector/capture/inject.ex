defmodule Electric.Postgres.Proxy.Injector.Capture.Inject do
  @moduledoc """
  Buffers responses from the backend until it receives a `ReadyForQuery`
  message. Once it has that message it injects the commands from the `inject`
  field and passes its buffered upstream responses and control to a `Sink` to
  absorb the responses.
  """

  defstruct [:inject, :wait, buffer: []]

  alias PgProtocol.Message, as: M
  alias Electric.Postgres.Proxy.Injector.Capture.Sink
  alias Electric.Postgres.Proxy.Injector.Send

  @type t() :: %__MODULE__{
          inject: [M.t()],
          wait: nil | [M.t()],
          buffer: [M.t()]
        }

  def new({back_msgs, skip_msgs}, buffer \\ []) do
    %__MODULE__{
      inject: back_msgs,
      wait: skip_msgs,
      buffer: buffer
    }
  end

  defimpl Electric.Postgres.Proxy.Injector.Capture do
    def recv_frontend(_m, _msg, _state, _send) do
      raise "shouldn't get a frontend message while sinking responses from backend"
    end

    def recv_backend(_inject, %M.ErrorResponse{} = msg, state, send) do
      {nil, state, Send.front(send, msg)}
    end

    def recv_backend(inject, %M.NoticeResponse{} = msg, state, send) do
      {inject, state, Send.front(send, msg)}
    end

    def recv_backend(i, %M.ReadyForQuery{} = msg, state, send) do
      {%Sink{
         buffer: [msg | i.buffer],
         wait: i.wait
       }, state, Send.back(send, i.inject)}
    end

    def recv_backend(i, msg, state, send) do
      {%{i | buffer: [msg | i.buffer]}, state, send}
    end
  end
end