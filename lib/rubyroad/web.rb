# frozen_string_literal: true

require "sinatra/base"
require "fileutils"
require "tmpdir"

module Rubyroad
  # Browser form that runs Integrator.generate — same artifacts as ./integrate.
  class DemoUI < Sinatra::Base
    set :root, File.expand_path("web", __dir__)
    set :views, File.expand_path("web/views", __dir__)
    set :public_folder, File.expand_path("web/public", __dir__)
    set :show_exceptions, false
    set :host_authorization, permitted_hosts: []

    get "/" do
      erb :index, locals: { error: nil, result: nil, warnings: [] }
    end

    post "/generate" do
      spec_path, cleanup = resolve_spec
      provider = params[:provider].to_s.strip
      provider = "novapay" if provider.empty?
      dest = Dir.mktmpdir("rubyroad-demo")
      result = Integrator.generate(
        spec: spec_path,
        provider: provider,
        out: dest,
        lang: "ruby",
        copy_rails: false
      )
      files = read_artifacts(result.fetch(:files))
      erb :index, locals: {
        error: nil,
        result: files,
        warnings: result.fetch(:warnings)
      }
    rescue InvalidSpecError, SpecLoadError, Error => e
      erb :index, locals: { error: e.message, result: nil, warnings: [] }
    ensure
      File.delete(cleanup) if cleanup && File.file?(cleanup)
    end

    private

    def resolve_spec
      if params[:use_example].to_s == "1"
        return [File.join(Rubyroad.root, "examples/provider_api.yaml"), nil]
      end

      upload = params[:spec]
      unless upload && upload[:tempfile]
        raise SpecLoadError, "Загрузите spec-файл или выберите пример NovaPay"
      end

      ext = File.extname(upload[:filename].to_s)
      ext = ".yaml" if ext.empty?
      path = File.join(Dir.tmpdir, "rubyroad-upload-#{Process.pid}#{ext}")
      File.binwrite(path, upload[:tempfile].read)
      [path, path]
    end

    def read_artifacts(paths)
      paths.each_with_object({}) do |path, acc|
        acc[File.basename(path)] = File.read(path)
      end
    end
  end
end
