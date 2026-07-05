#!/bin/bash
sed -i '' -e '/if let filter = try? JSONDecoder().decode(AssetFilterCriteria.self, from: sc.filterData) {/!b' -e 'n;n;n' -e 'a\
                } else if first == .allAssets {\
                    pendingAssetFilter = AssetFilterCriteria()
' /Users/mattranlett/Development/ViLM/ViLM/ViLM/ContentView.swift
