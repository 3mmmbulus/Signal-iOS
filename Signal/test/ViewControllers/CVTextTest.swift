//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import BonMot
import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

#if TESTABLE_BUILD

class CVTextTest: XCTestCase {
    func testTextViewMeasurement() {
        let configs = [
            CVTextViewConfig(text: "short", font: .dynamicTypeBody, textColor: .black),
            CVTextViewConfig(
                text: """
                Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.

                Aliquam malesuada porta dapibus. Aliquam fermentum faucibus velit, nec hendrerit massa fermentum nec. Nulla semper nibh eu justo accumsan auctor. Aenean justo eros, gravida at arcu sed, vulputate vulputate urna. Nulla et congue ligula. Vivamus non felis bibendum, condimentum elit et, tristique justo. Donec sed diam odio. In vitae pretium ante, sed rhoncus ex. Cras ultricies suscipit faucibus. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia curae; Donec imperdiet diam sit amet consequat aliquet. Donec eu dignissim dui. Suspendisse pellentesque metus turpis, non aliquam arcu egestas sed. Sed eu urna lacus. Pellentesque malesuada rhoncus nunc non sagittis. Aliquam bibendum, dolor id posuere volutpat, ex sem fermentum justo, non efficitur nisl lorem vel neque.

                Etiam sed felis nunc. Suspendisse vestibulum elit eu dignissim accumsan. Morbi tortor arcu, vulputate eu varius vel, varius ac sapien. Aenean ut efficitur augue. Sed semper diam at ipsum aliquet scelerisque. Pellentesque blandit quis sem non euismod. Sed accumsan tellus quis sapien fermentum, quis dapibus urna tincidunt. Nam mattis fermentum nisl, non eleifend tortor facilisis sed. Vestibulum vitae efficitur dolor. Nam ligula odio, molestie eu porttitor eu, dignissim ut nulla. Ut tempor diam id sapien mattis dignissim. Pellentesque accumsan nibh a velit convallis laoreet.
                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                text: """
                Λορεμ ιπσθμ δολορ σιτ αμετ, εα προ αλιι εσσε cετεροσ. Vιδερερ φαστιδιι αλβθcιθσ cθ σιτ, νε εστ vελιτ ατομορθμ. Ναμ νο ηινc cονγθε ρεcθσαβο, νε αλιqθαμ νεγλεγεντθρ εστ. Ποστεα περπετθα προ τε, ηασ νισλ περιcθλα ιδ. Ενιμ vιρτθτε αδ μεα. Θλλθμ αδμοδθμ ει vισ, εαμ vερι qθανδο αδ. Vελ ιλλθδ ετιαμ σιγνιφερθμqθε εα, μοδθσ θτιναμ παρτεμ vιξ εα.

                Ετ δθο σολεατ αθδιαμ, σιτ πθταντ σανcτθσ ιδ. Αν αccθμσαν ιντερπρεταρισ εθμ, μελ νολθισσε διγνισσιμ νε. Φορενσιβθσ ρεφορμιδανσ θλλαμcορπερ θτ ηασ, ναμ απεριαμ αλιqθιδ αν. Cθ σολθμ δελενιτ πατριοqθε εθμ, δετραcτο cονσετετθρ εστ τε. Νοvθμ σανcτθσ σεδ νο.
                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                text: """
                لكن لا بد أن أوضح لك أن كل هذه الأفكار المغلوطة حول استنكار  النشوة وتمجيد الألم نشأت بالفعل، وسأعرض لك التفاصيل لتكتشف حقيقة وأساس تلك السعادة البشرية، فلا أحد يرفض أو يكره أو يتجنب الشعور بالسعادة، ولكن بفضل هؤلاء الأشخاص الذين لا يدركون بأن السعادة لا بد أن نستشعرها بصورة أكثر عقلانية ومنطقية فيعرضهم هذا لمواجهة الظروف الأليمة، وأكرر بأنه لا يوجد من يرغب في الحب ونيل المنال ويتلذذ بالآلام، الألم هو الألم ولكن نتيجة لظروف ما قد تكمن السعاده فيما نتحمله من كد وأسي.

                و سأعرض مثال حي لهذا، من منا لم يتحمل جهد بدني شاق إلا من أجل الحصول على ميزة أو فائدة؟ ولكن من لديه الحق أن ينتقد شخص ما أراد أن يشعر بالسعادة التي لا تشوبها عواقب أليمة أو آخر أراد أن يتجنب الألم الذي ربما تنجم عنه بعض المتعة ؟
                علي الجانب الآخر نشجب ونستنكر هؤلاء الرجال المفتونون بنشوة اللحظة الهائمون في رغباتهم فلا يدركون ما يعقبها من الألم والأسي المحتم، واللوم كذلك يشمل هؤلاء الذين أخفقوا في واجباتهم نتيجة لضعف إرادتهم فيتساوي مع هؤلاء الذين يتجنبون وينأون عن تحمل الكدح والألم .

                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                text: """
                東沢族応同市総暮見送軟因旧野声。療名岡無会婚必文政職産首堪。原馬果制前興禁出部医保機出。賞響子恵横大厳著美無新殺常芸観載。上属力一本彰料必転指影未税廟赤府研。読煙責負力異寺先発事製量情停並。国圏場権電別新力際営測進必。事藤着人体存止作月玉社英題写予者。間引内一強客透人戦一家万暮読。種扱報崎若陣加府大姿平問写提化針離定。

                足己謙告保士清修根選暮区細理貨聞年半。読治問形球漂注出裏下公療演続。芸意記栄山写日撃掲国主治当性発。生意逃免渡資一取引裕督転。応点続果安罰村必禁家政拳。写禁法考証言心彫埼権川関員奏届新営覚掲。南応要参愛類娘都誰定尚同勝積鎌記写塁。政回過市主覧貨張加主子義空教対券。載捕構方聞度名出結字夜何動問暮理詳半話。
                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                text: """
                Lorem ipsum dolor sit amet 😟, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem 🧐, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac 🤞 ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.
                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                text: """
                He’s awesome. This album isn’t listed on his discography, but it’s a cool album of duets with Courtney Barnett: https://open.spotify.com/album/3gvo4nvimDdqA9c3y7Bptc?si=aA8z06HoQAG8Xl2MbhFiRQ
                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                text: """
                Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.

                東沢族応同市総暮見送軟因旧野声。療名岡無会婚必文政職産首堪。原馬果制前興禁出部医保機出。賞響子恵横大厳著美無新殺常芸観載。上属力一本彰料必転指影未税廟赤府研。読煙責負力異寺先発事製量情停並。国圏場権電別新力際営測進必。事藤着人体存止作月玉社英題写予者。間引内一強客透人戦一家万暮読。種扱報崎若陣加府大姿平問写提化針離定。

                Etiam sed felis nunc. Suspendisse vestibulum elit eu dignissim accumsan. Morbi tortor arcu, vulputate eu varius vel, varius ac sapien. Aenean ut efficitur augue. Sed semper diam at ipsum aliquet scelerisque. Pellentesque blandit quis sem non euismod. Sed accumsan tellus quis sapien fermentum, quis dapibus urna tincidunt. Nam mattis fermentum nisl, non eleifend tortor facilisis sed. Vestibulum vitae efficitur dolor. Nam ligula odio, molestie eu porttitor eu, dignissim ut nulla. Ut tempor diam id sapien mattis dignissim. Pellentesque accumsan nibh a velit convallis laoreet.
                """,
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                attributedText: NSAttributedString(string: "short"),
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                attributedText: NSAttributedString(string: "one\ntwo\nthree"),
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                attributedText: NSAttributedString.composed(of: [
                    Theme.iconImage(.video16),
                    "Some text",
                    "\n",
                    Theme.iconImage(.video16),
                    "Some text2",
                ]),
                font: .dynamicTypeBody,
                textColor: .black,
            ),
            CVTextViewConfig(
                attributedText: {
                    let labelText = NSMutableAttributedString()

                    labelText.appendTemplatedImage(
                        named: Theme.iconName(.compose16),
                        font: .dynamicTypeFootnote,
                        heightReference: .lineHeight,
                    )
                    labelText.append("  You changed the group name to “Test Group Call 2“.\n", attributes: [:])

                    labelText.appendTemplatedImage(
                        named: Theme.iconName(.photo16),
                        font: .dynamicTypeFootnote,
                        heightReference: .lineHeight,
                    )
                    labelText.append("  You updated the photo.", attributes: [:])

                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.paragraphSpacing = 12
                    paragraphStyle.alignment = .center
                    labelText.addAttributeToEntireString(.paragraphStyle, value: paragraphStyle)

                    return labelText
                }(),
                font: .dynamicTypeFootnote,
                textColor: .black,
                textAlignment: .center,
            ),
        ]

        for config in configs {
            for possibleWidth: CGFloat in stride(from: 100, to: 2000, by: 50) {
                let bodyTextLabelConfig = Self.bodyTextLabelConfig(textViewConfig: config)
                let measuredSize = CVText.measureBodyTextLabel(config: bodyTextLabelConfig, maxWidth: possibleWidth)
                // CVTextLabel only has a single measurement mechanism; there isn't
                // an independent way to verify the correctness of measurements.
                XCTAssertTrue(measuredSize.size.width > 0)
                XCTAssertTrue(measuredSize.size.width > 0)
            }
        }
    }

    static func bodyTextLabelConfig(textViewConfig: CVTextViewConfig) -> CVTextLabel.Config {
        return CVTextLabel.Config(
            text: textViewConfig.text,
            displayConfig: textViewConfig.displayConfiguration,
            font: textViewConfig.font,
            textColor: textViewConfig.textColor,
            selectionStyling: [.foregroundColor: UIColor.orange],
            textAlignment: textViewConfig.textAlignment ?? .natural,
            lineBreakMode: .byWordWrapping,
            numberOfLines: 0,
            cacheKey: textViewConfig.cacheKey,
            items: [],
            linkifyStyle: .underlined(bodyTextColor: textViewConfig.textColor),
        )
    }

    // FIXME: This test is broken.
//    func testLabelMeasurement() {
//        let configs = [
//            CVLabelConfig(text: "short", font: .dynamicTypeBody, textColor: .black, numberOfLines: 1),
//            CVLabelConfig(
//                text: """
//                Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.
//
//                Aliquam malesuada porta dapibus. Aliquam fermentum faucibus velit, nec hendrerit massa fermentum nec. Nulla semper nibh eu justo accumsan auctor. Aenean justo eros, gravida at arcu sed, vulputate vulputate urna. Nulla et congue ligula. Vivamus non felis bibendum, condimentum elit et, tristique justo. Donec sed diam odio. In vitae pretium ante, sed rhoncus ex. Cras ultricies suscipit faucibus. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia curae; Donec imperdiet diam sit amet consequat aliquet. Donec eu dignissim dui. Suspendisse pellentesque metus turpis, non aliquam arcu egestas sed. Sed eu urna lacus. Pellentesque malesuada rhoncus nunc non sagittis. Aliquam bibendum, dolor id posuere volutpat, ex sem fermentum justo, non efficitur nisl lorem vel neque.
//
//                Etiam sed felis nunc. Suspendisse vestibulum elit eu dignissim accumsan. Morbi tortor arcu, vulputate eu varius vel, varius ac sapien. Aenean ut efficitur augue. Sed semper diam at ipsum aliquet scelerisque. Pellentesque blandit quis sem non euismod. Sed accumsan tellus quis sapien fermentum, quis dapibus urna tincidunt. Nam mattis fermentum nisl, non eleifend tortor facilisis sed. Vestibulum vitae efficitur dolor. Nam ligula odio, molestie eu porttitor eu, dignissim ut nulla. Ut tempor diam id sapien mattis dignissim. Pellentesque accumsan nibh a velit convallis laoreet.
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 3
//            ),
//            CVLabelConfig(
//                text: """
//                Λορεμ ιπσθμ δολορ σιτ αμετ, εα προ αλιι εσσε cετεροσ. Vιδερερ φαστιδιι αλβθcιθσ cθ σιτ, νε εστ vελιτ ατομορθμ. Ναμ νο ηινc cονγθε ρεcθσαβο, νε αλιqθαμ νεγλεγεντθρ εστ. Ποστεα περπετθα προ τε, ηασ νισλ περιcθλα ιδ. Ενιμ vιρτθτε αδ μεα. Θλλθμ αδμοδθμ ει vισ, εαμ vερι qθανδο αδ. Vελ ιλλθδ ετιαμ σιγνιφερθμqθε εα, μοδθσ θτιναμ παρτεμ vιξ εα.
//
//                Ετ δθο σολεατ αθδιαμ, σιτ πθταντ σανcτθσ ιδ. Αν αccθμσαν ιντερπρεταρισ εθμ, μελ νολθισσε διγνισσιμ νε. Φορενσιβθσ ρεφορμιδανσ θλλαμcορπερ θτ ηασ, ναμ απεριαμ αλιqθιδ αν. Cθ σολθμ δελενιτ πατριοqθε εθμ, δετραcτο cονσετετθρ εστ τε. Νοvθμ σανcτθσ σεδ νο.
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 0
//
//            ),
//            CVLabelConfig(
//                text: """
//                لكن لا بد أن أوضح لك أن كل هذه الأفكار المغلوطة حول استنكار  النشوة وتمجيد الألم نشأت بالفعل، وسأعرض لك التفاصيل لتكتشف حقيقة وأساس تلك السعادة البشرية، فلا أحد يرفض أو يكره أو يتجنب الشعور بالسعادة، ولكن بفضل هؤلاء الأشخاص الذين لا يدركون بأن السعادة لا بد أن نستشعرها بصورة أكثر عقلانية ومنطقية فيعرضهم هذا لمواجهة الظروف الأليمة، وأكرر بأنه لا يوجد من يرغب في الحب ونيل المنال ويتلذذ بالآلام، الألم هو الألم ولكن نتيجة لظروف ما قد تكمن السعاده فيما نتحمله من كد وأسي.
//
//                و سأعرض مثال حي لهذا، من منا لم يتحمل جهد بدني شاق إلا من أجل الحصول على ميزة أو فائدة؟ ولكن من لديه الحق أن ينتقد شخص ما أراد أن يشعر بالسعادة التي لا تشوبها عواقب أليمة أو آخر أراد أن يتجنب الألم الذي ربما تنجم عنه بعض المتعة ؟
//                علي الجانب الآخر نشجب ونستنكر هؤلاء الرجال المفتونون بنشوة اللحظة الهائمون في رغباتهم فلا يدركون ما يعقبها من الألم والأسي المحتم، واللوم كذلك يشمل هؤلاء الذين أخفقوا في واجباتهم نتيجة لضعف إرادتهم فيتساوي مع هؤلاء الذين يتجنبون وينأون عن تحمل الكدح والألم .
//
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 0
//            ),
//            CVLabelConfig(
//                text: """
//                東沢族応同市総暮見送軟因旧野声。療名岡無会婚必文政職産首堪。原馬果制前興禁出部医保機出。賞響子恵横大厳著美無新殺常芸観載。上属力一本彰料必転指影未税廟赤府研。読煙責負力異寺先発事製量情停並。国圏場権電別新力際営測進必。事藤着人体存止作月玉社英題写予者。間引内一強客透人戦一家万暮読。種扱報崎若陣加府大姿平問写提化針離定。
//
//                足己謙告保士清修根選暮区細理貨聞年半。読治問形球漂注出裏下公療演続。芸意記栄山写日撃掲国主治当性発。生意逃免渡資一取引裕督転。応点続果安罰村必禁家政拳。写禁法考証言心彫埼権川関員奏届新営覚掲。南応要参愛類娘都誰定尚同勝積鎌記写塁。政回過市主覧貨張加主子義空教対券。載捕構方聞度名出結字夜何動問暮理詳半話。
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 0
//            ),
//            CVLabelConfig(
//                text: """
//                Lorem ipsum dolor sit amet 😟, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem 🧐, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac 🤞 ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 0
//            ),
//            CVLabelConfig(
//                text: """
//                Lorem ipsum dolor sit amet 😟, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem 🧐, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac 🤞 ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 2
//            ),
//            CVLabelConfig(
//                text: """
//                Lorem ipsum dolor sit amet 😟, consectetur adipiscing elit. Nullam lectus nulla, eleifend eget libero sit amet, tempor lobortis lacus. Nulla luctus id mi a auctor. Etiam bibendum sed ante et blandit. Phasellus bibendum commodo dapibus. Vivamus lorem diam, finibus vitae mi vel, dignissim ornare felis. Praesent nibh sem 🧐, bibendum vitae fringilla ac, sodales ut ipsum. Vestibulum metus magna, elementum eu dapibus in, faucibus at lacus. In ac 🤞 ornare nisi, ac fringilla sem. Sed ultricies sollicitudin semper. In hac habitasse platea dictumst.
//                """,
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 5,
//                lineBreakMode: .byTruncatingMiddle
//            ),
//            CVLabelConfig(
//                attributedText: NSAttributedString(string: "short"),
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 1
//            ),
//            CVLabelConfig(
//                attributedText: NSAttributedString(string: "one\ntwo\nthree"),
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 0
//            ),
//            CVLabelConfig(
//                attributedText: NSAttributedString.composed(of: [
//                    Theme.iconImage(.video16), "Some text", "\n", Theme.iconImage(.video16), "Some text2"
//                ]),
//                font: .dynamicTypeBody,
//                textColor: .black,
//                numberOfLines: 0
//            ),
//            CVLabelConfig(
//                attributedText: {
//                    let labelText = NSMutableAttributedString()
//
//                    labelText.appendTemplatedImage(named: Theme.iconName(.compose16),
//                                                   font: .dynamicTypeFootnote,
//                                                   heightReference: .lineHeight)
//                    labelText.append("  You changed the group name to “Test Group Call 2“.\n", attributes: [:])
//
//                    labelText.appendTemplatedImage(named: Theme.iconName(.photo16),
//                                                   font: .dynamicTypeFootnote,
//                                                   heightReference: .lineHeight)
//                    labelText.append("  You updated the photo.", attributes: [:])
//
//                    let paragraphStyle = NSMutableParagraphStyle()
//                    paragraphStyle.paragraphSpacing = 12
//                    paragraphStyle.alignment = .center
//                    labelText.addAttributeToEntireString(.paragraphStyle, value: paragraphStyle)
//
//                    return labelText
//                }(),
//                font: .dynamicTypeFootnote,
//                textColor: .black,
//                numberOfLines: 0,
//                lineBreakMode: .byWordWrapping,
//                textAlignment: .center
//            )
//        ]
//
//        for config in configs {
//            for possibleWidth: CGFloat in stride(from: 100, to: 2000, by: 50) {
//                let viewSize = CVText.measureLabelUsingView(config: config, maxWidth: possibleWidth)
//                let defaultSize = CVText.measureLabelUsingLayoutManager(config: config, maxWidth: possibleWidth)
//                XCTAssertEqual(viewSize.width, defaultSize.width)
//                XCTAssertEqual(viewSize.height, defaultSize.height)
//            }
//        }
//    }

    func testLinkifyWithTruncation() {
        let fullText = NSMutableAttributedString(string: "https://signal.org/foo https://signal.org/bar/baz")
        let truncatedText = NSMutableAttributedString(string: "https://signal.org/foo https://signal.org/ba…")
        var dataItems = CVComponentBodyText.detectItems(
            text: DisplayableText.testOnlyInit(fullContent: .attributedText(fullText), truncatedContent: .attributedText(truncatedText)),
            hasPendingMessageRequest: false,
            shouldAllowLinkification: true,
            textWasTruncated: true,
            revealedSpoilerIds: Set(),
            interactionUniqueId: UUID().uuidString,
            interactionIdentifier: InteractionSnapshotIdentifier(timestamp: 0, authorAci: nil),
        )
        CVTextLabel.linkifyData(
            attributedText: truncatedText,
            linkifyStyle: .linkAttribute,
            items: dataItems,
        )
        var values: [String] = []
        var ranges: [NSRange] = []
        truncatedText.enumerateAttribute(.link, in: truncatedText.entireRange, options: []) { value, range, _ in
            if let value {
                values.append(value as! String)
                ranges.append(range)
            }
        }
        XCTAssertEqual(["https://signal.org/foo"], values)
        XCTAssertEqual([NSRange(location: 0, length: 22)], ranges)

        truncatedText.removeAttribute(.link, range: truncatedText.entireRange)
        dataItems = CVComponentBodyText.detectItems(
            text: DisplayableText.testOnlyInit(fullContent: .attributedText(fullText), truncatedContent: .attributedText(truncatedText)),
            hasPendingMessageRequest: false,
            shouldAllowLinkification: true,
            textWasTruncated: false,
            revealedSpoilerIds: Set(),
            interactionUniqueId: UUID().uuidString,
            interactionIdentifier: InteractionSnapshotIdentifier(timestamp: 0, authorAci: nil),
        )
        CVTextLabel.linkifyData(
            attributedText: fullText,
            linkifyStyle: .linkAttribute,
            items: dataItems,
        )
        values.removeAll()
        ranges.removeAll()
        fullText.enumerateAttribute(.link, in: fullText.entireRange, options: []) { value, range, _ in
            if let value {
                values.append(value as! String)
                ranges.append(range)
            }
        }
        XCTAssertEqual(["https://signal.org/foo", "https://signal.org/bar/baz"], values)
        XCTAssertEqual([NSRange(location: 0, length: 22), NSRange(location: 23, length: 26)], ranges)

        // Should work on more than just URLs.
        let fullEmail = NSMutableAttributedString(string: "moxie@example.com moxie@signal.org")
        let truncatedEmail = NSMutableAttributedString(string: "moxie@example.com moxie@signal.or…")
        dataItems = CVComponentBodyText.detectItems(
            text: DisplayableText.testOnlyInit(fullContent: .attributedText(fullEmail), truncatedContent: .attributedText(truncatedEmail)),
            hasPendingMessageRequest: false,
            shouldAllowLinkification: true,
            textWasTruncated: true,
            revealedSpoilerIds: Set(),
            interactionUniqueId: UUID().uuidString,
            interactionIdentifier: InteractionSnapshotIdentifier(timestamp: 0, authorAci: nil),
        )
        CVTextLabel.linkifyData(
            attributedText: truncatedEmail,
            linkifyStyle: .linkAttribute,
            items: dataItems,
        )
        values.removeAll()
        truncatedEmail.enumerateAttribute(.link, in: truncatedEmail.entireRange, options: []) { value, _, _ in
            if let value {
                values.append(value as! String)
            }
        }
        XCTAssertEqual(["mailto:moxie@example.com"], values)

        let fullPhone = NSMutableAttributedString(string: "+16505555555 +16505555555")
        let truncatedPhone = NSMutableAttributedString(string: "+16505555555 +1650555555…")
        dataItems = CVComponentBodyText.detectItems(
            text: DisplayableText.testOnlyInit(fullContent: .attributedText(fullPhone), truncatedContent: .attributedText(truncatedPhone)),
            hasPendingMessageRequest: false,
            shouldAllowLinkification: true,
            textWasTruncated: true,
            revealedSpoilerIds: Set(),
            interactionUniqueId: UUID().uuidString,
            interactionIdentifier: InteractionSnapshotIdentifier(timestamp: 0, authorAci: nil),
        )
        CVTextLabel.linkifyData(
            attributedText: truncatedPhone,
            linkifyStyle: .linkAttribute,
            items: dataItems,
        )
        values.removeAll()
        truncatedPhone.enumerateAttribute(.link, in: truncatedPhone.entireRange, options: []) { value, _, _ in
            if let value {
                values.append(value as! String)
            }
        }
        XCTAssertEqual(["tel:+16505555555"], values)
    }
}

extension CVLabelConfig {

    fileprivate init(
        text: String,
        font: UIFont,
        textColor: UIColor,
        numberOfLines: Int = 1,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
    ) {
        self.init(
            text: .text(text),
            displayConfig: .forUnstyledText(font: font, textColor: textColor),
            font: font,
            textColor: textColor,
            numberOfLines: numberOfLines,
            lineBreakMode: lineBreakMode,
        )
    }

    fileprivate init(
        attributedText: NSAttributedString,
        font: UIFont,
        textColor: UIColor,
        numberOfLines: Int = 1,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        textAlignment: NSTextAlignment? = nil,
    ) {
        self.init(
            text: .attributedText(attributedText),
            displayConfig: .forUnstyledText(font: font, textColor: textColor),
            font: font,
            textColor: textColor,
            numberOfLines: numberOfLines,
            lineBreakMode: lineBreakMode,
            textAlignment: textAlignment,
        )
    }
}

extension CVTextViewConfig {

    fileprivate init(
        text: String,
        font: UIFont,
        textColor: UIColor,
    ) {
        self.init(
            text: .text(text),
            font: font,
            textColor: textColor,
            displayConfiguration: .forUnstyledText(font: font, textColor: textColor),
            linkifyStyle: .linkAttribute,
            linkItems: [],
            matchedSearchRanges: [],
        )
    }

    fileprivate init(
        attributedText: NSAttributedString,
        font: UIFont,
        textColor: UIColor,
        textAlignment: NSTextAlignment? = nil,
    ) {
        self.init(
            text: .attributedText(attributedText),
            font: font,
            textColor: textColor,
            textAlignment: textAlignment,
            displayConfiguration: .forUnstyledText(font: font, textColor: textColor),
            linkifyStyle: .linkAttribute,
            linkItems: [],
            matchedSearchRanges: [],
        )
    }
}

#endif

/// Tellomi（#1205，需求 bubbles-and-motion 3.1）：气泡分组按发出时间，3 分钟内算一组；上面那条挂着表情回应时断开。
class TellomiBubbleGroupingTest: SignalBaseTest {

    private let sentAt: UInt64 = 1_790_000_000_000

    private func incoming(sentAt: UInt64, receivedAt: UInt64, thread: TSThread) -> TSIncomingMessage {
        let builder: TSIncomingMessageBuilder = .withDefaultValues(thread: thread, timestamp: sentAt, receivedAtTimestamp: receivedAt)
        return builder.build()
    }

    /// 离线一阵再上线：隔了 10 分钟发的两条几乎同时收到。按收到时间会并成一组，按发出时间不会。
    func testMessagesSentFarApartButReceivedTogetherAreNotGrouped() {
        let thread = ContactThreadFactory().create()
        let receivedAt = sentAt + 20 * UInt64.minuteInMs
        let upper = incoming(sentAt: sentAt, receivedAt: receivedAt, thread: thread)
        let lower = incoming(sentAt: sentAt + 10 * UInt64.minuteInMs, receivedAt: receivedAt + 1000, thread: thread)

        XCTAssertFalse(CVItemViewState.tellomiCanClusterMessages(upper: upper, upperHasReactions: false, lower: lower))
    }

    /// 晚到的消息：一分钟内发的两条，隔了 10 分钟才收到后一条，仍是一组。
    func testMessagesSentTogetherButReceivedApartAreGrouped() {
        let thread = ContactThreadFactory().create()
        let upper = incoming(sentAt: sentAt, receivedAt: sentAt + 1000, thread: thread)
        let lower = incoming(sentAt: sentAt + UInt64.minuteInMs, receivedAt: sentAt + 10 * UInt64.minuteInMs, thread: thread)

        XCTAssertTrue(CVItemViewState.tellomiCanClusterMessages(upper: upper, upperHasReactions: false, lower: lower))
    }

    func testThreeMinutesIsTheBoundary() {
        let thread = ContactThreadFactory().create()
        let upper = incoming(sentAt: sentAt, receivedAt: sentAt, thread: thread)
        let justInside = incoming(sentAt: sentAt + 3 * UInt64.minuteInMs - 1, receivedAt: sentAt, thread: thread)
        let atBoundary = incoming(sentAt: sentAt + 3 * UInt64.minuteInMs, receivedAt: sentAt, thread: thread)

        XCTAssertTrue(CVItemViewState.tellomiCanClusterMessages(upper: upper, upperHasReactions: false, lower: justInside))
        XCTAssertFalse(CVItemViewState.tellomiCanClusterMessages(upper: upper, upperHasReactions: false, lower: atBoundary))
    }

    /// 显示顺序和发出顺序不一致（下面那条发得更早）时按相差多久算。
    func testOrderOfSendingDoesNotMatter() {
        let thread = ContactThreadFactory().create()
        let upper = incoming(sentAt: sentAt + UInt64.minuteInMs, receivedAt: sentAt, thread: thread)
        let lower = incoming(sentAt: sentAt, receivedAt: sentAt + 1000, thread: thread)

        XCTAssertTrue(CVItemViewState.tellomiCanClusterMessages(upper: upper, upperHasReactions: false, lower: lower))
    }

    /// 回应条挂在上面那条下面，和下一条之间断开。
    func testReactionOnTheUpperMessageBreaksTheGroup() {
        let thread = ContactThreadFactory().create()
        let upper = incoming(sentAt: sentAt, receivedAt: sentAt, thread: thread)
        let lower = incoming(sentAt: sentAt + 1000, receivedAt: sentAt + 1000, thread: thread)

        XCTAssertFalse(CVItemViewState.tellomiCanClusterMessages(upper: upper, upperHasReactions: true, lower: lower))
    }
}

/// Tellomi（#1205，设计规范 bubbles-and-motion-design.md 第 2 节，owner 选 A「圆润」）：小尾巴画进气泡的轮廓里。
class TellomiBubbleTailTest: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
    private let corners = BubbleConfiguration.Corners.segmented(sharpCorners: [], sharpCornerRadius: 4, wideCornerRadius: 18)

    private func path(tailOnRight: Bool?) -> UIBezierPath {
        let tail = tailOnRight.map { BubbleConfiguration.Tail(isOnRight: $0) }
        return BubbleConfiguration(corners: corners, tail: tail).bubblePath(for: rect)
    }

    /// 尾巴在哪边，轮廓都是顺时针：媒体的内阴影靠「轮廓 + 反向外框」按非零环绕填色，方向错了气泡里面整块是黑的
    /// （2026-10-17 对方发的带说明的图片 / 地点消息的地图）。
    func testTheOutlineIsClockwiseOnBothSides() {
        for tailOnRight in [true, false, nil] as [Bool?] {
            XCTAssertGreaterThan(Self.signedArea(path(tailOnRight: tailOnRight)), 0, "tail on right: \(String(describing: tailOnRight))")
        }
    }

    /// The inner shadow the media view draws (`OWSBubbleShapeView` `.innerShadow`): outline + the outer rect reversed, filled
    /// non-zero. Inside the bubble must stay empty.
    func testTheMediaInnerShadowLeavesTheInsideEmptyOnBothSides() {
        for tailOnRight in [true, false] {
            let shadow = path(tailOnRight: tailOnRight).copy() as! UIBezierPath
            shadow.append(UIBezierPath(rect: rect.insetBy(dx: -2, dy: -2)).reversing())
            shadow.usesEvenOddFillRule = false
            XCTAssertFalse(shadow.contains(CGPoint(x: rect.midX, y: rect.midY)), "tail on right: \(tailOnRight)")
            XCTAssertTrue(shadow.contains(CGPoint(x: rect.midX, y: rect.minY - 1)), "tail on right: \(tailOnRight)")
        }
    }

    /// Shoelace area of the path's points (curves by their end points), y down: positive = clockwise on screen.
    private static func signedArea(_ path: UIBezierPath) -> CGFloat {
        var points = [CGPoint]()
        path.cgPath.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .addCurveToPoint: points.append(e.points[2])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        var area: CGFloat = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    func testTailOnTheRightReplacesTheBottomRightCorner() {
        let path = path(tailOnRight: true)
        let body = BubbleConfiguration.Tail(isOnRight: true).bodyRect(in: rect)
        XCTAssertEqual(body, CGRect(x: 0, y: 0, width: 200 - 6.3, height: 40))

        // 尖端在气泡本体外、贴着底边
        XCTAssertTrue(path.contains(CGPoint(x: body.maxX + 3, y: rect.maxY - 0.5)))
        // 尾巴只有 14 高：再往上就在外面
        XCTAssertFalse(path.contains(CGPoint(x: body.maxX + 3, y: rect.maxY - 20)))
        // 本体右下角不再是圆角，被尾巴接上
        XCTAssertTrue(path.contains(CGPoint(x: body.maxX - 1, y: rect.maxY - 1)))
        // 其余的角照旧是圆的
        XCTAssertFalse(path.contains(CGPoint(x: body.maxX - 1, y: rect.minY + 1)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.minX + 1, y: rect.maxY - 1)))

        // 伸出约 6.1（按控制点是 6.3），不出整块的范围；底边和气泡底边齐平
        let bounds = path.bounds
        XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.01)
        XCTAssertGreaterThan(bounds.maxX, body.maxX + 6)
        XCTAssertLessThanOrEqual(bounds.maxX, rect.maxX + 0.01)
        XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.01)
    }

    func testTailOnTheLeftIsTheMirrorImage() {
        let right = path(tailOnRight: true)
        let left = path(tailOnRight: false)
        let points = [
            CGPoint(x: 196.7, y: 39.5),
            CGPoint(x: 196.7, y: 20),
            CGPoint(x: 192.7, y: 39),
            CGPoint(x: 192.7, y: 1),
            CGPoint(x: 100, y: 20),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 39),
        ]
        for point in points {
            XCTAssertEqual(right.contains(point), left.contains(CGPoint(x: rect.maxX - point.x, y: point.y)), "\(point)")
        }
        XCTAssertGreaterThanOrEqual(left.bounds.minX, rect.minX - 0.01)
        XCTAssertLessThan(left.bounds.minX, rect.minX + 0.3)
    }

    func testWithoutATailTheBubbleIsUnchanged() {
        XCTAssertEqual(path(tailOnRight: nil).bounds, rect)
        XCTAssertTrue(path(tailOnRight: nil).contains(CGPoint(x: 199, y: 20)))
        XCTAssertFalse(path(tailOnRight: nil).contains(CGPoint(x: 199, y: 39)))
    }

    func testContentKeepsItsPlaceOnTheTailSide() {
        XCTAssertEqual(BubbleConfiguration.Tail(isOnRight: true).contentInsets, UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6.3))
        XCTAssertEqual(BubbleConfiguration.Tail(isOnRight: false).contentInsets, UIEdgeInsets(top: 0, left: 6.3, bottom: 0, right: 0))
    }

    /// 和 Android TellomiBubbleTail.shouldDraw 同一规则。
    func testOnlyTheLastMessageOfAGroupWithABubbleInTheConversationGetsATail() {
        XCTAssertTrue(CVComponentMessage.tellomiShouldDrawTail(isLastInCluster: true, hasReactions: false, hasBubbleBackground: true, styleType: .`default`))
        XCTAssertFalse(CVComponentMessage.tellomiShouldDrawTail(isLastInCluster: false, hasReactions: false, hasBubbleBackground: true, styleType: .`default`))
        XCTAssertFalse(CVComponentMessage.tellomiShouldDrawTail(isLastInCluster: true, hasReactions: true, hasBubbleBackground: true, styleType: .`default`))
        XCTAssertFalse(CVComponentMessage.tellomiShouldDrawTail(isLastInCluster: true, hasReactions: false, hasBubbleBackground: false, styleType: .`default`))
        XCTAssertFalse(CVComponentMessage.tellomiShouldDrawTail(isLastInCluster: true, hasReactions: false, hasBubbleBackground: true, styleType: .messageDetails))
    }

    /// 会话页渲染时样式常是 placeholder（走查模拟器上打日志量到的），这时也要画；只按 `== .default` 判断就一个尾巴都没有。
    func testConversationRenderedWithThePlaceholderStyleStillGetsATail() {
        XCTAssertTrue(CVComponentMessage.tellomiShouldDrawTail(isLastInCluster: true, hasReactions: false, hasBubbleBackground: true, styleType: .placeholder))
    }

    /// 气泡视图在尾巴那一侧比包装大出 `Tail.extent`，滑动回复的位移照旧叠加；复用 reset 后回到原样。
    func testSwipeWrapperExtendsTheBubbleOnTheTailSide() {
        let wrapper = SwipeToReplyWrapper(name: "test", useSlowOffset: false, shouldReset: true)
        wrapper.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let bubble = UIView()
        wrapper.subview = bubble
        wrapper.tellomiSubviewOutsets = BubbleConfiguration.Tail(isOnRight: true).contentInsets
        wrapper.layoutIfNeeded()
        XCTAssertEqual(bubble.frame, CGRect(x: 0, y: 0, width: 106.3, height: 40))

        wrapper.offset = CGPoint(x: -20, y: 0)
        wrapper.layoutIfNeeded()
        XCTAssertEqual(bubble.frame, CGRect(x: -20, y: 0, width: 106.3, height: 40))

        wrapper.reset()
        XCTAssertEqual(wrapper.tellomiSubviewOutsets, .zero)
    }

    /// 壁纸模糊视图一个 cell 只建一次、从不 reset，每次配置加的布局块都留在它身上。先配一条有尾巴的、复用、再配一条没尾巴的：
    /// 内容还是放在中间那一层里，这层还是它的子视图——旧布局块排的视图都还在它里面，不会走到「Missing superview」。
    func testReusedBlurViewOnlyEverHostsTheTailLayer() {
        let blurView = ManualLayoutView(name: "blur") // 代替 CVWallpaperBlurView：整个用例里不 reset
        let tailContentView = ManualLayoutView(name: "tail")
        let content = UIView()

        // 第一条：尾巴在右，内容缩回原来的宽度
        blurView.frame = CGRect(x: 0, y: 0, width: 106.3, height: 40)
        CVComponentMessage.tellomiHostContent(content, in: blurView, tailContentView: tailContentView, insets: BubbleConfiguration.Tail(isOnRight: true).contentInsets)
        blurView.layoutIfNeeded()
        tailContentView.layoutIfNeeded()
        XCTAssertEqual(tailContentView.frame, blurView.bounds)
        XCTAssertEqual(content.frame, CGRect(x: 0, y: 0, width: 100, height: 40))

        // 复用：同 CVComponentMessage 的 reset()——内容和中间层摘下来，中间层 reset，模糊视图不动
        content.removeFromSuperview()
        tailContentView.removeFromSuperview()
        tailContentView.reset()

        // 第二条：没尾巴，还是这个模糊视图
        CVComponentMessage.tellomiHostContent(content, in: blurView, tailContentView: tailContentView, insets: .zero)
        XCTAssertTrue(tailContentView.superview === blurView)
        XCTAssertTrue(content.superview === tailContentView)
        XCTAssertEqual(blurView.subviews.count, 1)

        blurView.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        blurView.layoutIfNeeded()
        tailContentView.layoutIfNeeded()
        XCTAssertEqual(tailContentView.frame, blurView.bounds)
        XCTAssertEqual(content.frame, CGRect(x: 0, y: 0, width: 120, height: 40))
    }
}

/// Tellomi（#1205，设计规范第 2 节）：「正在输入」气泡和对方的消息一样带尾巴，在对方那侧的下角；有壁纸时才带描边（和上游一样）。
class TellomiTypingTailTest: XCTestCase {

    func testTypingBubbleHasATailOnTheOtherPersonsSide() {
        let ltr = CVComponentTypingIndicator.tellomiBubbleConfig(hasWallpaper: false, isDarkThemeEnabled: false, isRTL: false)
        XCTAssertEqual(ltr.tail, BubbleConfiguration.Tail(isOnRight: false))
        XCTAssertNil(ltr.stroke)

        let rtl = CVComponentTypingIndicator.tellomiBubbleConfig(hasWallpaper: true, isDarkThemeEnabled: true, isRTL: true)
        XCTAssertEqual(rtl.tail, BubbleConfiguration.Tail(isOnRight: true))
        XCTAssertNotNil(rtl.stroke)
    }

    func testTypingBubbleOutlineIncludesTheTail() {
        let config = CVComponentTypingIndicator.tellomiBubbleConfig(hasWallpaper: false, isDarkThemeEnabled: false, isRTL: false)
        let rect = CGRect(x: 0, y: 0, width: 70 + BubbleConfiguration.Tail.extent, height: 36)
        let path = config.bubblePath(for: rect)

        // 尖端在左下、气泡本体外
        XCTAssertTrue(path.contains(CGPoint(x: 3, y: 35.5)))
        // 尾巴只有 14 高
        XCTAssertFalse(path.contains(CGPoint(x: 3, y: 10)))
        // 右下角照旧是胶囊的圆角
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 1, y: 35)))
    }
}

/// Tellomi（规范 #1204 第 2 节最后一条，owner 2026-09-26 定照规范加）：气泡在尾巴那一侧多留 e = 6，尾巴不贴屏幕边、不压头像。
/// 和 Android `TellomiBubbleTailMarginTest` 同一组数：我发的离屏幕边 16 + 6；单聊里对方的离屏幕边 16 + 6；群里对方的离头像 8 + 6。
/// 用会话页同一套渲染（`CVLoader` 单条渲染 + `CVCellView`，同 `MockConversationView`）真排一次版，量气泡的排版位置（不含尾巴外扩）。
class TellomiBubbleTailMarginTest: SignalBaseTest {

    private let viewWidth: CGFloat = 402
    private let otherAci = Aci.randomForTesting()

    @MainActor
    func testMyBubbleEnds16Plus6FromTheScreenEdge() throws {
        register()
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let message = write { tx in
            let factory = OutgoingMessageFactory()
            factory.threadCreator = { _ in thread }
            return factory.create(transaction: tx)
        }

        let (cell, messageView) = try render(message, in: thread)
        let content = messageView.tellomiContentFrameForTesting(in: cell)
        XCTAssertEqual(cell.bounds.size.width - content.maxX, 16 + 6, accuracy: 0.5, "我发的离屏幕右边：\(content) in \(cell.bounds)")
    }

    @MainActor
    func testTheirBubbleStarts16Plus6FromTheScreenEdgeInA1to1Chat() throws {
        register()
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let message = write { tx in
            let factory = IncomingMessageFactory()
            factory.threadCreator = { _ in thread }
            return factory.create(transaction: tx)
        }

        let (cell, messageView) = try render(message, in: thread)
        let content = messageView.tellomiContentFrameForTesting(in: cell)
        XCTAssertNil(messageView.tellomiAvatarFrameForTesting(in: cell), "单聊不带头像")
        XCTAssertEqual(content.minX, 16 + 6, accuracy: 0.5, "单聊里对方的离屏幕左边：\(content)")
    }

    /// 群里对方的消息：e 加在头像和气泡之间（8 → 14）。单测环境渲染不了群里的头像——`AvatarBuilder` 把
    /// `contactManagerRef` 强转成 `OWSContactsManager`，测试里是 `FakeContactsManager`，会崩——所以这里测排版参数，
    /// 群里的实际排版需上设备。
    func testInAGroupTheExtraSpaceGoesBetweenTheAvatarAndTheBubble() {
        let margin = BubbleConfiguration.Tail.sideMargin
        let group = CVComponentMessage.tellomiTailSideSpace(isIncoming: true, followsAvatar: true, margin: margin)
        XCTAssertEqual(ConversationStyle.messageStackSpacing + group.afterAvatar, 8 + 6, "头像和气泡之间")
        XCTAssertEqual(group.leading, 0)
        XCTAssertEqual(group.trailing, 0)

        let oneToOne = CVComponentMessage.tellomiTailSideSpace(isIncoming: true, followsAvatar: false, margin: margin)
        XCTAssertEqual(oneToOne.leading, 6, "单聊加在最前面")
        XCTAssertEqual(oneToOne.afterAvatar, 0)

        let mine = CVComponentMessage.tellomiTailSideSpace(isIncoming: false, followsAvatar: false, margin: margin)
        XCTAssertEqual(mine.trailing, 6, "我发的加在最后面")
        XCTAssertEqual(mine.leading + mine.afterAvatar, 0)
    }

    /// 「正在输入」气泡也带尾巴（a52），离屏幕边、离头像和对方的消息一样
    @MainActor
    func testTheirTypingBubbleStarts16Plus6FromTheScreenEdgeInA1to1Chat() throws {
        register()
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let typing = TypingIndicatorInteraction(threadUniqueId: thread.uniqueId, timestamp: NSDate.ows_millisecondTimeStamp(), address: SignalServiceAddress(otherAci))

        let cell = try renderCell(typing, in: thread)
        let typingView = try XCTUnwrap(cell.componentView as? CVComponentTypingIndicator.CVComponentViewTypingIndicator)
        let bubble = typingView.tellomiBubbleFrameForTesting(in: cell)
        XCTAssertNil(typingView.tellomiAvatarFrameForTesting(in: cell), "单聊不带头像")
        XCTAssertEqual(bubble.minX, 16 + 6, accuracy: 0.5, "单聊里打字气泡离屏幕左边：\(bubble)")
    }

    /// 群里的打字气泡：e 加在头像和气泡之间。和上面群里那条同一个原因（单测环境渲染不了群头像），测排版参数；实际排版需上设备。
    func testInAGroupTheTypingBubbleGetsTheExtraSpaceAfterTheAvatar() {
        let margin = BubbleConfiguration.Tail.sideMargin
        let group = CVComponentTypingIndicator.tellomiTailSideSpace(hasAvatar: true, margin: margin)
        XCTAssertEqual(ConversationStyle.messageStackSpacing + group.afterAvatar, 8 + 6, "头像和打字气泡之间")
        XCTAssertEqual(group.leading, 0)

        let oneToOne = CVComponentTypingIndicator.tellomiTailSideSpace(hasAvatar: false, margin: margin)
        XCTAssertEqual(oneToOne.leading, 6, "单聊加在最前面")
        XCTAssertEqual(oneToOne.afterAvatar, 0)
    }

    // MARK: -

    private func register() {
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    @MainActor
    private func render(_ interaction: TSInteraction, in thread: TSThread) throws -> (CVCellView, CVComponentMessage.CVComponentViewMessage) {
        let cell = try renderCell(interaction, in: thread)
        let messageView = try XCTUnwrap(cell.componentView as? CVComponentMessage.CVComponentViewMessage)
        return (cell, messageView)
    }

    /// 同 `MockConversationView`：会话页样式单独渲染一条，放进 `CVCellView` 排版
    @MainActor
    private func renderCell(_ interaction: TSInteraction, in thread: TSThread) throws -> CVCellView {
        let viewWidth = self.viewWidth
        let renderItem = try XCTUnwrap(read { tx -> CVRenderItem? in
            let conversationStyle = ConversationStyle(
                type: .`default`,
                thread: thread,
                viewWidth: viewWidth,
                hasWallpaper: false,
                shouldDimWallpaperInDarkMode: false,
                chatColor: DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(for: thread, tx: tx),
            )
            return CVLoader.buildStandaloneRenderItem(
                interaction: interaction,
                thread: thread,
                conversationStyle: conversationStyle,
                spoilerState: SpoilerRenderState(),
                groupNameColors: GroupNameColors.forThread(thread),
                transaction: tx,
            )
        })
        // 只是给渲染当回调对象，用例里不点任何东西（`MockConversationView` 本来就实现了全部回调）；存起来保活
        let componentDelegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        componentDelegates.append(componentDelegate)
        let cell = CVCellView()
        cell.configure(renderItem: renderItem, componentDelegate: componentDelegate)
        cell.frame = CGRect(origin: .zero, size: CGSize(width: viewWidth, height: renderItem.cellMeasurement.cellSize.height))
        cell.layoutIfNeeded()
        return cell
    }

    private var componentDelegates: [UIView] = []
}
