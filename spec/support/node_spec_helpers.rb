module NodeSpecHelpers
  def node_staging_env
    {:runtime_info => {
        :name => "node06",
        :version => "0.6.8",
        :description => "Node.js",
        :executable => ENV["VCAP_RUNTIME_NODE06"] || "node",
        :npm => npm_executable
    },
     :framework_info => {
         :name =>"node",
         :runtimes =>[{"node"=>{"default"=>true}}, {"node06"=>{"default"=>false}}],
         :detection =>[{"*.js"=>"."}]
     }}
  end

  def npm_executable
    ENV["NPM"] || (ENV["VCAP_RUNTIME_NODE06"] ? File.join(File.dirname(ENV["VCAP_RUNTIME_NODE06"]), "npm") : nil)
  end

  def pending_unless_npm_provided
    pending "use NPM to set npm path" unless node_staging_env[:runtime_info][:npm]
  end

  def package_config(package_dir)
    package_config_file = File.join(package_dir, "package.json")
    Yajl::Parser.parse(File.new(package_config_file, "r"))
  end

  def test_package_version(package_dir, version)
    File.exist?(package_dir).should be_true
    package_info = package_config(package_dir)
    package_info["version"].should eql(version)
  end
end