defmodule Strata.SSHKeyCallback do
  @moduledoc """
  `:ssh_client_key_api` callback that loads an explicit `IdentityFile` path
  (including custom key filenames and passphrases) before falling back to
  Erlang's default `:ssh_file` key discovery in `user_dir`.
  """
  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, host, port, algorithm, opts) do
    :ssh_file.is_host_key(key, host, port, algorithm, opts)
  end

  @impl true
  def add_host_key(host, port, key, opts) do
    :ssh_file.add_host_key(host, port, key, opts)
  end

  @impl true
  def user_key(algorithm, opts) do
    {identity_file, passphrase} =
      opts
      |> Keyword.get(:key_cb_private, [])
      |> then(fn priv ->
        {Keyword.get(priv, :identity_file), Keyword.get(priv, :passphrase)}
      end)

    case decode_explicit_identity(identity_file, algorithm, passphrase) do
      {:ok, key} -> {:ok, key}
      _ -> :ssh_file.user_key(algorithm, opts)
    end
  end

  defp decode_explicit_identity(path, algorithm, passphrase)
       when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    pwd =
      if is_binary(passphrase) and passphrase != "",
        do: String.to_charlist(passphrase),
        else: :ignore

    with {:ok, pem} <- File.read(expanded),
         {:ok, [{key, _attrs} | _]} <- :ssh_file.decode_ssh_file(:private, algorithm, pem, pwd) do
      {:ok, key}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_explicit_identity(_path, _algorithm, _passphrase), do: :error
end
