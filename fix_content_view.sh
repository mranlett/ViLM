#!/bin/bash
sed -i '' -e 's/libraryURL: selectedLibraryURL)$/libraryURL: selectedLibraryURL,\n                            pendingFilter: $pendingActorFilter,\n                            pendingSort: $pendingActorSort,\n                            pendingSortAscending: $pendingActorSortAscending)/g' /Users/mattranlett/Development/ViLM/ViLM/ViLM/ContentView.swift

sed -i '' -e 's/filteredAssetContext: $filteredAssetContext)$/filteredAssetContext: $filteredAssetContext,\n                            pendingFilter: $pendingAssetFilter,\n                            pendingSort: $pendingAssetSort,\n                            pendingSortAscending: $pendingAssetSortAscending)/g' /Users/mattranlett/Development/ViLM/ViLM/ViLM/ContentView.swift
