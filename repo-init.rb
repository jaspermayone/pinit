#!/usr/bin/env ruby

require 'optparse'
require 'octokit'
require 'fileutils'
require 'open3'
require 'haikunator'
require 'yaml'
require 'replicate'  # Try just the namespace
require 'down'

class RepoInitializer
  def initialize
    @options = {
      verbose: false,
      name: nil,
      template: nil
    }
    load_config
  end

  def run(args)
    parse_options(args)
    # Make sure we have a template repo before proceeding
    if !@options[:template] && config_exists?
      config = YAML.load_file(File.expand_path('~/.github-init-config.yml'))
      @options[:template] = config['template_repo']
    end

    if !@options[:template]
      puts "Error: No template repository specified. Please provide it in config file or via --template parameter"
      exit 1
    end

    create_and_setup_repo
  rescue StandardError => e
    puts "Error: #{e.message}"
    exit 1
  end

  def config_exists?
    File.exist?(File.expand_path('~/.github-init-config.yml'))
  end

  private

  def load_config
    config_path = File.expand_path('~/.github-init-config.yml')
    return unless File.exist?(config_path)

    config = YAML.load_file(config_path)
    @github_token = config['github_token']
    @bot_git_email = config['bot_git_email']
    @bot_git_name = config['bot_git_name']
    @github_username = config['github_username']
    @replicate_token = config['replicate_token']

    # Configure Replicate with the token
    Replicate.configure do |config|
      config.api_token = @replicate_token
    end
  end

  def parse_options(args)
    OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

      # Repository options
      opts.on("-n", "--name NAME", "Repository name") do |name|
        @options[:name] = name
      end

      opts.on("-t", "--template REPO", "Template repository (e.g., username/repo)") do |repo|
        @options[:template] = repo
      end

      # GitHub configuration
      opts.on("--github-token TOKEN", "GitHub API token") do |token|
        @github_token = token
      end

      opts.on("--github-username USERNAME", "GitHub username") do |username|
        @github_username = username
      end

      # Git configuration
      opts.on("--git-email EMAIL", "Git email for commit signing") do |email|
        @bot_git_email = email
      end

      opts.on("--git-name NAME", "Git name for commit signing") do |name|
        @bot_git_name = name
      end

      # Image generation
      opts.on("--replicate-token TOKEN", "Replicate API token for image generation") do |token|
        @replicate_token = token
      end

      # Other options
      opts.on("-v", "--verbose", "Enable verbose output") do
        @options[:verbose] = true
      end

      opts.on("-g", "--generate", "Generate a new name (can be used multiple times)") do
        generate_and_show_name
        exit
      end

      opts.on("-h", "--help", "Show this message") do
        puts opts
        exit
      end
    end.parse!(args)

    validate_configuration
  end

  def validate_configuration
    # Only validate if arguments were provided
    return unless ARGV.any?

    missing = []
    missing << "GitHub token" unless @github_token
    missing << "GitHub username" unless @github_username
    missing << "Git email" unless @bot_git_email
    missing << "Git name" unless @bot_git_name
    missing << "Template repository" unless @options[:template]
    missing << "Replicate token" unless @replicate_token

    unless missing.empty?
      puts "Missing required configuration. Please provide either in config file or as parameters:"
      missing.each { |m| puts "- #{m}" }
      exit 1
    end
  end

  def generate_and_show_name
    5.times do
      puts "Generated name option: #{Haikunator.haikunate(0)}"
    end
  end

  def prompt_for_name
    loop do
      suggested_name = Haikunator.haikunate(0)
      print "Suggested repository name: #{suggested_name}\nUse this name? (y/n/q to quit) "

      case gets.chomp.downcase
      when 'y'
        return suggested_name
      when 'q'
        exit
      end
    end
  end

  def create_and_setup_repo
    @repo_name = @options[:name] || prompt_for_name

    puts "Creating repository: #{@repo_name}"

    # Create GitHub repository
    client = Octokit::Client.new(access_token: @github_token)
    repo = client.create_repository(
      @repo_name,
      private: true,
      auto_init: false
    )

    # Clone template repository
    clone_and_setup_repo(repo.ssh_url)

    puts "Repository successfully created and initialized!"
    puts "GitHub URL: #{repo.html_url}"
  end

  def generate_readme_image
    puts "Generating project banner image..."

    # Create a prompt based on the repository name
    prompt = "A modern, minimalist logo for a software project called #{@repo_name}, " \
             "digital art style, clean design, white background"

    # Use the model
    model = Replicate.client.retrieve_model("stability-ai/sdxl")
    version = model.latest_version

    # Run prediction
    prediction = version.predict(
      prompt: prompt,
      negative_prompt: "text, words, letters, blurry, low quality",
      width: 1200,
      height: 400,
      num_outputs: 1,
      scheduler: "K_EULER",
      num_inference_steps: 50,
      guidance_scale: 7.5
    )

    # Download the generated image
    image_url = prediction.output  # Changed from prediction[0]
    tempfile = Down.download(image_url)

    # Move the image to the assets directory
    FileUtils.mkdir_p('assets')
    FileUtils.mv(tempfile.path, 'assets/banner.png')

    puts "Banner image generated successfully!"
  end

  def update_readme_with_banner
    readme_path = 'README.md'
    return unless File.exist?(readme_path)

    content = File.read(readme_path)
    banner_markdown = "![Project Banner](assets/banner.png)\n\n"

    # Add banner at the top of the README
    if content.include?('![Project Banner]')
      content.sub!(/!\[Project Banner\].*$\n\n/m, banner_markdown)
    else
      content = banner_markdown + content
    end

    File.write(readme_path, content)
  end

  def clone_and_setup_repo(ssh_url)
    puts "Debug: Using template repository: #{@options[:template]}" if @options[:verbose]

    # Create directory and initialize git
    FileUtils.mkdir_p(@repo_name)
    Dir.chdir(@repo_name) do
      # First initialize a new git repository
      run_command('git init')

      # Configure bot user for signing commits
      run_command("git config user.email \"#{@bot_git_email}\"")
      run_command("git config user.name \"#{@bot_git_name}\"")

      # Clone template repository contents
      clone_cmd = "git pull git@github.com:#{@options[:template]}.git main"
      puts "Debug: Running clone command: #{clone_cmd}" if @options[:verbose]
      run_command(clone_cmd)

      # Generate and add banner image
      generate_readme_image
      update_readme_with_banner

      # Add remote and push
      run_command("git remote add origin #{ssh_url}")
      run_command('git add .')
      run_command('git commit -S -m "Initial commit"')
      run_command('git branch -M main')
      run_command('git push -u origin main')
    end
  end

  def run_command(command)
    puts "> #{command}" if @options[:verbose]

    output, status = Open3.capture2e(command)
    if status.success?
      puts output if @options[:verbose]
    else
      raise "Command failed: #{output}"
    end
  end
end

# Handle interrupt gracefully
Signal.trap("INT") do
  puts "\nInterrupted by user"
  exit 1
end

if __FILE__ == $PROGRAM_NAME
  RepoInitializer.new.run(ARGV)
end
