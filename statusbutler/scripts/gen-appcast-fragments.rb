#!/usr/bin/env ruby
# frozen_string_literal: true

# T-056a（B1·发布链 / A2·S11·OG-FR-200）：读 dist/ 产物，生成 Sparkle appcast 的
# <item> XML 片段到 stdout（嵌入 appcast.xml 的 <channel> 内，不生成整份文件）。
# 用法: ruby scripts/gen-appcast-fragments.rb [dist目录]（缺省 ../dist）
#
# EdDSA 签名占位变量：SPARKLE_EDDSA_KEY（环境变量）。
# 本脚本不做签名运算——真实签名应由上游管道用 Sparkle sign_update 对 DMG 计算后注入；
# 缺省时输出注释警告并 exit 2（宁可不出片，不出不可信的 appcast 条目）。
# enclosure url 占位：DMG_DOWNLOAD_URL（环境变量，缺省 __ENCLOSURE_URL__，组装时替换）；
# length 为 DMG 真实字节数；版本三值读自 dist 内 .app 的 Info.plist。

require 'open3'
require 'time'

def fail_usage(message)
  warn "错误: #{message}"
  warn '用法: ruby scripts/gen-appcast-fragments.rb [dist目录]（缺省 ../dist）'
  exit 2
end

def plutil_extract(key, plist_path)
  out, _err, status = Open3.capture3('plutil', '-extract', key, 'raw', '-o', '-', plist_path)
  return nil unless status.success?
  value = out.strip
  value.empty? ? nil : value
end

def xml_escape(text)
  text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
end

# 参数白名单：至多一个位置参数（dist 目录），任何选项样式参数一律拒绝
fail_usage("未知参数 '#{ARGV[1]}'（仅支持一个可选 dist 目录参数）") if ARGV.size > 1
unless ARGV.empty?
  fail_usage("未知参数 '#{ARGV[0]}'（仅支持一个可选 dist 目录参数）") if ARGV[0].start_with?('-')
end
dist = ARGV.empty? ? File.expand_path('../dist', __dir__) : File.expand_path(ARGV[0])
fail_usage("dist 目录不存在: #{dist}") unless File.directory?(dist)

# 产物发现：DMG 取 mtime 最新一份（release-app.sh 有清场纪律，正常恰好一份）；
# 版本元数据取 .app 内 Info.plist（Open3 传参不经 shell，防路径注入）
dmgs = Dir.glob(File.join(dist, '*.dmg')).sort_by { |f| File.mtime(f) }
fail_usage('dist 下未找到 .dmg 产物') if dmgs.empty?
apps = Dir.glob(File.join(dist, '*.app')).sort_by { |f| File.mtime(f) }
fail_usage('dist 下未找到 .app 产物（appcast 需要其 Info.plist 版本元数据）') if apps.empty?
dmg = dmgs.last
plist = File.join(apps.last, 'Contents', 'Info.plist')

app_name = plutil_extract('CFBundleName', plist) || 'StatusButler'
short_version = plutil_extract('CFBundleShortVersionString', plist)
fail_usage("无法从 #{plist} 读取 CFBundleShortVersionString") if short_version.nil?
build = plutil_extract('CFBundleVersion', plist)
fail_usage("无法从 #{plist} 读取 CFBundleVersion") if build.nil?
min_system = plutil_extract('LSMinimumSystemVersion', plist) || '13.0'

# EDDSA 签名闸：缺 key = 无法生成可信条目 → 注释警告 + exit 2
signature = ENV['SPARKLE_EDDSA_KEY'].to_s.strip
if signature.empty?
  puts '<!-- 警告: 未设置 SPARKLE_EDDSA_KEY（Sparkle EdDSA 签名），已拒绝生成不可信的 appcast 条目 -->'
  warn '警告: 缺少 SPARKLE_EDDSA_KEY；真实签名请由上游管道用 Sparkle sign_update 对 DMG 计算后注入'
  exit 2
end

# enclosure url 占位替换：DMG_DOWNLOAD_URL → 缺省 __ENCLOSURE_URL__（组装 appcast 时替换）
url = ENV['DMG_DOWNLOAD_URL'].to_s.strip
url = '__ENCLOSURE_URL__' if url.empty?

puts "<!-- Sparkle appcast item 片段（#{xml_escape(app_name)} #{xml_escape(short_version)}）: 由 scripts/gen-appcast-fragments.rb 生成，嵌入 appcast 的 channel 内 -->"
puts '<item>'
puts "    <title>#{xml_escape(app_name)} #{xml_escape(short_version)}</title>"
puts "    <pubDate>#{Time.now.rfc2822}</pubDate>"
puts "    <sparkle:minimumSystemVersion>#{xml_escape(min_system)}</sparkle:minimumSystemVersion>"
puts '    <enclosure'
puts "        url=\"#{xml_escape(url)}\""
puts "        sparkle:edSignature=\"#{xml_escape(signature)}\""
puts "        length=\"#{File.size(dmg)}\""
puts '        type="application/x-apple-diskimage"'
puts "        sparkle:version=\"#{xml_escape(build)}\""
puts "        sparkle:shortVersionString=\"#{xml_escape(short_version)}\""
puts '    />'
puts '</item>'
