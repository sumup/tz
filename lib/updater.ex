if Code.ensure_loaded?(Mint.HTTP) do
  defmodule Tz.Updater do
    @moduledoc false

    require Logger

    alias Tz.Compiler
    alias Tz.PeriodsProvider
    alias Tz.HTTP.HTTPClient
    alias Tz.HTTP.HTTPResponse

    def maybe_recompile() do
      if maybe_update_tz_database() == :updated do
        Logger.info("Tz is recompiling time zone periods...")
        Code.compiler_options(ignore_module_conflict: true)
        Compiler.compile()
        Code.compiler_options(ignore_module_conflict: false)
        Logger.info("Tz compilation done")
      end
    end

    def fetch_iana_tz_version() do
      case HTTPClient.request("GET", "/time-zones/tzdb/version", hostname: "data.iana.org") do
        %HTTPResponse{body: body, status_code: 200} ->
          {:ok, body |> List.first() |> String.trim()}

        _ ->
          :error
      end
    end

    defp is_offline?, do: Application.fetch_env!(:tz, :offline_mode) == true

    defp maybe_update_tz_database() do
      if is_offline?() do
        maybe_update_from_archive()
      else
        maybe_update_from_iana()
      end
    end

    defp maybe_update_from_iana do
      case fetch_iana_tz_version() do
        {:ok, latest_version} ->
          if latest_version != PeriodsProvider.version() do
            case update_tz_database_from_iana(latest_version) do
              :ok ->
                delete_tz_database(PeriodsProvider.version())
                :updated

              _ ->
                :error
            end
          end

        :error ->
          Logger.error("Tz failed to read the latest version of the IANA time zone database")
          :no_update
      end
    end

    defp maybe_update_from_archive do
      archive_path = Application.fetch_env!(:tz, :archive_path)

      latest_archive_name =
        archive_path
        |> File.ls!()
        |> Enum.sort()
        |> List.last()

      latest_version = String.trim(latest_archive_name, "tzdata")

      if latest_version != PeriodsProvider.version() do
        latest_archive = [archive_path, latest_archive_name] |> Path.join() |> File.read!()

        case extract_tz_database(latest_version, latest_archive) do
          :ok ->
            delete_tz_database(PeriodsProvider.version())
            :updated

          _ ->
            :error
        end
      end
    end

    defp update_tz_database_from_iana(version) do
      case download_tz_database(version) do
        {:ok, content} ->
          extract_tz_database(version, content)
          :ok

        :error ->
          Logger.error(
            "Tz failed to download the latest archived IANA time zone database (version #{version})"
          )

          :error
      end
    end

    defp download_tz_database(version) do
      Logger.info("Tz is downloading the latest IANA time zone database (version #{version})...")

      case HTTPClient.request("GET", "/time-zones/releases/tzdata#{version}.tar.gz",
             hostname: "data.iana.org"
           ) do
        %HTTPResponse{body: body, status_code: 200} ->
          Logger.info("Tz download done")
          {:ok, body}

        _ ->
          :error
      end
    end

    defp extract_tz_database(version, content) do
      tmp_archive_path = Path.join(:code.priv_dir(:tz), "tzdata#{version}.tar.gz")
      tz_data_dir = "tzdata#{version}"
      :ok = File.write!(tmp_archive_path, content)

      files_to_extract = [
        'africa',
        'antarctica',
        'asia',
        'australasia',
        'backward',
        'etcetera',
        'europe',
        'northamerica',
        'southamerica',
        'iso3166.tab',
        'zone1970.tab'
      ]

      :ok =
        :erl_tar.extract(tmp_archive_path, [
          :compressed,
          {:cwd, Path.join(:code.priv_dir(:tz), tz_data_dir)},
          {:files, files_to_extract}
        ])

      :ok = File.rm!(tmp_archive_path)
    end

    defp delete_tz_database(version) do
      Path.join(:code.priv_dir(:tz), "tzdata#{version}")
      |> File.rm_rf!()
    end
  end
end
